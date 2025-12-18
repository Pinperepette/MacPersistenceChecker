import Foundation
import Combine

/// Main service for monitoring persistence changes in real-time
final class PersistenceMonitor: ObservableObject {
    /// Shared singleton instance
    @MainActor
    static let shared = PersistenceMonitor()

    // MARK: - Published State (Main Actor)

    /// Current monitoring state
    @MainActor @Published private(set) var state: MonitorState = .stopped

    /// Whether monitoring is currently active
    @MainActor var isMonitoring: Bool { state == .running }

    /// Last detected change
    @MainActor @Published private(set) var lastChange: MonitorChange? = nil

    /// Total changes detected since monitoring started
    @MainActor @Published private(set) var changeCount: Int = 0

    /// Unacknowledged change count
    @MainActor @Published private(set) var unacknowledgedCount: Int = 0

    // MARK: - Dependencies

    private let watcherManager = DirectoryWatcherManager()
    private let baseline: MonitorBaseline
    private let changeDetector: ChangeDetector
    private let configuration: MonitorConfiguration
    private let scanner: ScannerOrchestrator

    // Background queue for scanning operations
    private let scanQueue = DispatchQueue(label: "com.mpc.persistence-monitor.scan", qos: .utility)

    private var cancellables = Set<AnyCancellable>()

    // Scan debouncing - avoid multiple scans for rapid changes
    private var pendingScans: [PersistenceCategory: DispatchWorkItem] = [:]
    private let pendingScansLock = NSLock()
    private let scanDebounceInterval: TimeInterval = 2.0

    // MARK: - Initialization

    @MainActor
    private init() {
        self.baseline = MonitorBaseline.shared
        self.changeDetector = ChangeDetector()
        self.configuration = MonitorConfiguration.shared
        self.scanner = ScannerOrchestrator()

        loadUnacknowledgedCount()
    }

    // MARK: - Public Methods

    /// Start monitoring all enabled categories
    @MainActor
    func startMonitoring() async {
        guard state == .stopped || state.displayName.hasPrefix("Error") else {
            print("[PersistenceMonitor] Cannot start - current state: \(state)")
            return
        }

        state = .starting
        NSLog("[PersistenceMonitor] Starting monitoring...")

        // Request notification permission first
        do {
            try await NotificationDispatcher.shared.requestPermission()
        } catch {
            print("[PersistenceMonitor] Notification permission error: \(error)")
            // Continue anyway - monitoring still works, just no notifications
        }

        // Move heavy work off main thread
        let result = await Task.detached(priority: .utility) { [weak self] () -> Result<Int, Error> in
            guard let self = self else { return .failure(MonitorError.scanFailed("Self deallocated")) }

            do {
                // Create baseline if needed (off main thread)
                let hasBaseline = self.baseline.hasBaseline
                if !hasBaseline {
                    print("[PersistenceMonitor] No baseline found, creating from current state...")

                    // Get items from AppState on main thread
                    let items = await MainActor.run { AppState.shared.items }

                    if items.isEmpty {
                        // Need to scan first - do it on background
                        print("[PersistenceMonitor] No items, running initial scan...")
                        let scannedItems = await self.scanner.scanAll()

                        // Update AppState on main thread
                        await MainActor.run {
                            AppState.shared.items = scannedItems
                            AppState.shared.lastScanDate = Date()
                        }

                        try self.baseline.createBaseline(from: scannedItems)
                    } else {
                        try self.baseline.createBaseline(from: items)
                    }
                }

                // Get enabled categories
                let categories = await MainActor.run { self.configuration.allEnabledCategories }

                // Setup watchers (this is quick)
                var watchCount = 0
                for category in categories {
                    if !category.monitoredPaths.isEmpty {
                        await MainActor.run {
                            self.watcherManager.startWatching(category: category, configuration: self.configuration)
                        }
                        watchCount += 1
                    }
                }

                return .success(watchCount)

            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let watchCount):
            // Setup watcher callback on main thread
            watcherManager.onChangeDetected = { [weak self] event in
                NSLog("[PersistenceMonitor] onChangeDetected callback fired!")
                self?.handleDirectoryChangeAsync(event)
            }

            state = .running
            configuration.monitoringEnabled = true
            NSLog("[PersistenceMonitor] Monitoring started for %d categories", watchCount)

        case .failure(let error):
            state = .error(error.localizedDescription)
            print("[PersistenceMonitor] Failed to start: \(error)")
        }
    }

    /// Stop all monitoring
    @MainActor
    func stopMonitoring() {
        guard state == .running else { return }

        state = .stopping
        print("[PersistenceMonitor] Stopping monitoring...")

        // Cancel pending scans
        pendingScansLock.lock()
        for workItem in pendingScans.values {
            workItem.cancel()
        }
        pendingScans.removeAll()
        pendingScansLock.unlock()

        // Stop all watchers
        watcherManager.stopAll()

        state = .stopped
        configuration.monitoringEnabled = false
        print("[PersistenceMonitor] Monitoring stopped")
    }

    /// Toggle monitoring state
    @MainActor
    func toggleMonitoring() async {
        if isMonitoring {
            stopMonitoring()
        } else {
            await startMonitoring()
        }
    }

    /// Update baseline with current state
    func updateBaseline() async throws {
        let items = await MainActor.run { AppState.shared.items }
        try baseline.updateBaseline(from: items)
        print("[PersistenceMonitor] Baseline updated with \(items.count) items")
    }

    /// Reset baseline and change history
    @MainActor
    func resetBaseline() throws {
        try baseline.reset()
        try DatabaseManager.shared.pruneChangeHistory(olderThanDays: 0)  // Clear all
        changeCount = 0
        lastChange = nil
        unacknowledgedCount = 0
        print("[PersistenceMonitor] Baseline and history reset")
    }

    /// Acknowledge all changes
    @MainActor
    func acknowledgeAllChanges() {
        try? DatabaseManager.shared.acknowledgeAllChanges()
        unacknowledgedCount = 0
        Task {
            await NotificationDispatcher.shared.clearBadge()
        }
    }

    /// Get change history
    func getChangeHistory(limit: Int = 100) -> [ChangeHistoryEntry] {
        (try? DatabaseManager.shared.getChangeHistory(limit: limit)) ?? []
    }

    /// Get baseline statistics
    func getBaselineStats() -> MonitorBaseline.BaselineStats {
        baseline.getStats()
    }

    // MARK: - Private Methods

    @MainActor
    private func loadUnacknowledgedCount() {
        unacknowledgedCount = (try? DatabaseManager.shared.getUnacknowledgedChangeCount()) ?? 0
    }

    /// Handle directory change asynchronously (off main thread)
    private func handleDirectoryChangeAsync(_ event: DirectoryChangeEvent) {
        NSLog("[PersistenceMonitor] Directory change: %@ in %@ - %@", event.eventType.rawValue, event.category.displayName, event.path.lastPathComponent)

        // Debounce scans for the same category
        pendingScansLock.lock()
        pendingScans[event.category]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            NSLog("[PersistenceMonitor] Debounce completed, starting targeted scan...")
            Task {
                await self?.performTargetedScan(for: event.category)
            }
        }

        pendingScans[event.category] = workItem
        pendingScansLock.unlock()

        NSLog("[PersistenceMonitor] Scheduled scan in %.1f seconds", scanDebounceInterval)
        // Schedule scan after debounce interval on background queue
        scanQueue.asyncAfter(deadline: .now() + scanDebounceInterval, execute: workItem)
    }

    /// Perform targeted scan (runs on background)
    private func performTargetedScan(for category: PersistenceCategory) async {
        NSLog("[PersistenceMonitor] Performing targeted scan for %@", category.displayName)

        // Get baseline for this category (thread-safe)
        guard let baselineItems = try? baseline.getBaseline(for: category) else {
            NSLog("[PersistenceMonitor] No baseline for %@", category.displayName)
            return
        }
        NSLog("[PersistenceMonitor] Baseline has %d items", baselineItems.count)

        // Perform targeted scan of just this category (background operation)
        NSLog("[PersistenceMonitor] Scanning category...")
        let newItems = await scanner.scan(category: category)
        NSLog("[PersistenceMonitor] Scan found %d items", newItems.count)

        // Detect changes (CPU-bound, already on background)
        let changes = changeDetector.detectChanges(
            baseline: baselineItems,
            current: newItems,
            category: category
        )
        NSLog("[PersistenceMonitor] Change detection found %d changes", changes.count)

        guard !changes.isEmpty else {
            NSLog("[PersistenceMonitor] No changes detected for %@", category.displayName)
            return
        }

        NSLog("[PersistenceMonitor] Detected %d changes in %@", changes.count, category.displayName)

        // Get config value once
        let minRelevance = await MainActor.run { configuration.minimumRelevanceScore }
        NSLog("[PersistenceMonitor] Min relevance threshold: %d", minRelevance)

        // Process each change
        for change in changes {
            let relevance = changeDetector.calculateRelevance(change)
            NSLog("[PersistenceMonitor] Change: %@ - %@ (relevance: %d)", change.type.rawValue, change.item?.name ?? "unknown", relevance)

            // Save to history (database operation)
            let historyEntry = ChangeHistoryEntry(from: change, relevanceScore: relevance)
            try? DatabaseManager.shared.saveChangeHistory(historyEntry)

            // Only notify for relevant changes
            if relevance >= minRelevance {
                NSLog("[PersistenceMonitor] Sending notification...")
                // Send notification (may involve main thread)
                await NotificationDispatcher.shared.send(change: change, relevance: relevance)
                NSLog("[PersistenceMonitor] Notification sent!")

                // Update UI state on main thread
                await MainActor.run { [weak self] in
                    self?.lastChange = change
                    self?.changeCount += 1
                    self?.unacknowledgedCount += 1
                }
            } else {
                NSLog("[PersistenceMonitor] Change below threshold (%d < %d): %@", relevance, minRelevance, change.item?.name ?? "unknown")
            }
        }

        // Update baseline for this category with new state
        try? baseline.updateBaseline(items: newItems, for: category)
        NSLog("[PersistenceMonitor] Baseline updated")

        // Update AppState with new items on main thread
        await MainActor.run {
            AppState.shared.items.removeAll { $0.category == category }
            AppState.shared.items.append(contentsOf: newItems)
        }
        NSLog("[PersistenceMonitor] AppState updated")
    }
}

// MARK: - Auto-Start Support

extension PersistenceMonitor {
    /// Initialize monitoring if auto-start is enabled (call with delay)
    @MainActor
    func initializeIfAutoStart() async {
        // Delay to let the app fully initialize first
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds

        if configuration.autoStartMonitoring && configuration.monitoringEnabled {
            await startMonitoring()
        }
    }
}

// MARK: - Status Display

extension PersistenceMonitor {
    /// Get a human-readable status string
    @MainActor
    var statusDescription: String {
        switch state {
        case .stopped:
            return "Monitoring stopped"
        case .starting:
            return "Starting monitoring..."
        case .running:
            let count = watcherManager.watchedCategories.count
            return "Monitoring \(count) categories"
        case .stopping:
            return "Stopping monitoring..."
        case .error(let msg):
            return "Error: \(msg)"
        }
    }

    /// Get baseline status description
    var baselineDescription: String {
        let stats = baseline.getStats()
        if stats.isEmpty {
            return "No baseline"
        }

        let dateStr: String
        if let date = stats.createdAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            dateStr = formatter.localizedString(for: date, relativeTo: Date())
        } else {
            dateStr = "unknown"
        }

        return "\(stats.totalItems) items (created \(dateStr))"
    }
}
