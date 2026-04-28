import Foundation
import Combine
import UserNotifications

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

            // Send initial notification with current mode
            await sendStartupNotification(categoryCount: watchCount)

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

        // Check if AI is active
        let isAIActive = await MainActor.run { AIConfiguration.shared.isAIActive }
        let minRelevance = await MainActor.run { configuration.minimumRelevanceScore }
        NSLog("[PersistenceMonitor] AI active: %@, Min relevance threshold: %d", isAIActive ? "YES" : "NO", minRelevance)

        // Process each change
        for change in changes {
            let relevance = changeDetector.calculateRelevance(change)
            NSLog("[PersistenceMonitor] Change: %@ - %@ (relevance: %d)", change.type.rawValue, change.item?.name ?? "unknown", relevance)

            // Save to history (database operation)
            let historyEntry = ChangeHistoryEntry(from: change, relevanceScore: relevance)
            try? DatabaseManager.shared.saveChangeHistory(historyEntry)

            // Check notification cooldown (don't repeat same item)
            let itemIdentifier = change.item?.identifier ?? "unknown"
            let canNotify = configuration.canNotify(forIdentifier: itemIdentifier)

            if !canNotify {
                NSLog("[PersistenceMonitor] Skipping notification - cooldown active for: %@", itemIdentifier)
                continue
            }

            // Knowledge graph gate: concept resolver primary, per-item rule
            // matcher fallback. Runs in both AI on/off modes.
            if let item = change.item {
                let fingerprint = ItemFingerprint.make(from: item)
                let confThreshold = 0.7

                // 1) Concept resolver (multi-concept aware, with reasoning).
                let conceptIDs = ConceptIngestor.shared.conceptIDs(forFingerprint: fingerprint.hash)
                let resolved = ConceptResolver.shared.resolve(item: item, linkedConceptIDs: conceptIDs)
                if case .classified(let verdict, let confidence) = resolved.outcome {
                    NSLog("[PersistenceMonitor] Concept resolver verdict=%@ conf=%.2f via %@",
                          verdict.rawValue, confidence, resolved.winningConceptID ?? "?")
                    switch verdict {
                    case .benign:
                        configuration.recordNotification(forIdentifier: itemIdentifier)
                        _ = try? KnowledgeGraphStore.shared.recordSighting(fingerprint)
                        continue
                    case .watchlist, .malicious:
                        await NotificationDispatcher.shared.send(change: change, relevance: max(relevance, 80))
                        configuration.recordNotification(forIdentifier: itemIdentifier)
                        await MainActor.run { [weak self] in
                            self?.lastChange = change
                            self?.changeCount += 1
                            self?.unacknowledgedCount += 1
                        }
                        _ = try? KnowledgeGraphStore.shared.recordSighting(fingerprint)
                        continue
                    }
                }

                // 2) Fallback to per-item RuleMatcher (legacy single-item user
                //    trust + fingerprint-bound AI rules from before the concept
                //    layer). Same semantics as before.
                let lookup = RuleMatcher.shared.evaluate(item: item)
                switch lookup {
                case .knownBenign(let rule, let confidence) where confidence >= confThreshold:
                    NSLog("[PersistenceMonitor] Rule fallback benign (rule=%@, conf=%.2f)", rule.id, confidence)
                    try? KnowledgeGraphStore.shared.confirmRule(id: rule.id)
                    _ = try? KnowledgeGraphStore.shared.recordSighting(fingerprint, matchedRuleId: rule.id)
                    configuration.recordNotification(forIdentifier: itemIdentifier)
                    continue

                case .knownThreat(let rule, let confidence, let isMalicious) where confidence >= confThreshold:
                    NSLog("[PersistenceMonitor] Rule fallback threat (rule=%@, conf=%.2f, malicious=%@)",
                          rule.id, confidence, isMalicious ? "YES" : "NO")
                    try? KnowledgeGraphStore.shared.confirmRule(id: rule.id)
                    _ = try? KnowledgeGraphStore.shared.recordSighting(fingerprint, matchedRuleId: rule.id)
                    await NotificationDispatcher.shared.send(change: change, relevance: max(relevance, 80))
                    configuration.recordNotification(forIdentifier: itemIdentifier)
                    await MainActor.run { [weak self] in
                        self?.lastChange = change
                        self?.changeCount += 1
                        self?.unacknowledgedCount += 1
                    }
                    continue

                default:
                    _ = try? KnowledgeGraphStore.shared.recordSighting(fingerprint)
                }
            }

            if isAIActive {
                // AI-powered analysis
                await processChangeWithAI(change)
            } else {
                // Traditional relevance-based notification
                if relevance >= minRelevance {
                    NSLog("[PersistenceMonitor] Sending notification...")
                    await NotificationDispatcher.shared.send(change: change, relevance: relevance)
                    NSLog("[PersistenceMonitor] Notification sent!")

                    // Record notification to prevent repeats
                    configuration.recordNotification(forIdentifier: itemIdentifier)

                    await MainActor.run { [weak self] in
                        self?.lastChange = change
                        self?.changeCount += 1
                        self?.unacknowledgedCount += 1
                    }
                } else {
                    NSLog("[PersistenceMonitor] Change below threshold (%d < %d): %@", relevance, minRelevance, change.item?.name ?? "unknown")
                }
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

    // MARK: - Startup Notification

    /// Send notification when monitoring starts showing current mode
    @MainActor
    private func sendStartupNotification(categoryCount: Int) async {
        let aiConfig = AIConfiguration.shared
        let isAI = aiConfig.useAI && aiConfig.isAPIKeyValid

        NSLog("[PersistenceMonitor] Startup notification - useAI: %@, isAPIKeyValid: %@, isAIActive: %@",
              aiConfig.useAI ? "YES" : "NO",
              aiConfig.isAPIKeyValid ? "YES" : "NO",
              isAI ? "YES" : "NO")

        let content = UNMutableNotificationContent()

        if isAI {
            content.title = "Monitoring Started (AI Mode)"
            let intervalText = AIConfiguration.intervalOptions.first { $0.0 == aiConfig.aiCheckInterval }?.1 ?? "\(Int(aiConfig.aiCheckInterval))s"
            content.body = "Claude AI will analyze changes. Check: \(intervalText), Notify: ≥\(aiConfig.notificationThreshold.displayName)"
        } else {
            content.title = "Monitoring Started (Standard Mode)"
            content.body = "Real-time monitoring active. \(categoryCount) categories, Relevance threshold: \(configuration.minimumRelevanceScore)"
        }

        content.sound = .default
        content.categoryIdentifier = "MONITORING_STATUS"

        let request = UNNotificationRequest(
            identifier: "monitoring-started-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            NSLog("[PersistenceMonitor] Startup notification sent")
        } catch {
            NSLog("[PersistenceMonitor] Failed to send startup notification: %@", error.localizedDescription)
        }
    }

    // MARK: - AI-Powered Change Analysis

    /// Process a change using Claude AI analysis
    private func processChangeWithAI(_ change: MonitorChange) async {
        guard let item = change.item else {
            NSLog("[PersistenceMonitor] No item in change, skipping AI analysis")
            return
        }

        NSLog("[PersistenceMonitor] Starting AI analysis for: %@", item.name)

        // Determine change type and details
        let changeType: String
        var changeDetails: [String]? = nil

        switch change.type {
        case .added:
            changeType = "added"
        case .removed:
            changeType = "removed"
        case .modified:
            changeType = "modified"
            // Include modification details from change.details
            if !change.details.isEmpty {
                changeDetails = change.details.map { "\($0.field): \($0.oldValue) → \($0.newValue)" }
            }
        case .enabled:
            changeType = "enabled"
        case .disabled:
            changeType = "disabled"
        }

        // Create detailed analysis with all item info
        let analysis = await MainActor.run {
            ClaudeAPIClient.createDetailedAnalysis(
                from: item,
                changeType: changeType,
                changes: changeDetails
            )
        }

        // Call Claude API
        do {
            let apiClient = await MainActor.run { ClaudeAPIClient() }
            let response = try await apiClient.analyzeItem(analysis)

            NSLog("[PersistenceMonitor] AI response - shouldNotify: %@, severity: %@", response.shouldNotify ? "YES" : "NO", response.severity)

            // Check if we should notify based on AI decision and threshold
            let threshold = await MainActor.run { AIConfiguration.shared.notificationThreshold }
            let responseSeverity = AISeverity(rawValue: response.severity) ?? .info

            if response.shouldNotify && responseSeverity >= threshold {
                NSLog("[PersistenceMonitor] AI recommends notification - sending...")

                // Send AI-generated notification
                await sendAINotification(
                    item: item,
                    changeType: changeType,
                    response: response
                )

                // Record notification to prevent repeats
                configuration.recordNotification(forIdentifier: item.identifier)

                // Update UI state
                await MainActor.run { [weak self] in
                    self?.lastChange = change
                    self?.changeCount += 1
                    self?.unacknowledgedCount += 1
                }
            } else {
                NSLog("[PersistenceMonitor] AI says no notification needed or below threshold")
            }

        } catch {
            NSLog("[PersistenceMonitor] AI analysis failed: %@", error.localizedDescription)
            // Fallback to simple notification on error
            await NotificationDispatcher.shared.send(change: change, relevance: 50)
        }
    }

    /// Send notification with AI-generated content
    private func sendAINotification(
        item: PersistenceItem,
        changeType: String,
        response: ClaudeAPIClient.SingleItemAnalysisResponse
    ) async {
        let content = UNMutableNotificationContent()
        content.title = response.title
        content.subtitle = "\(item.category.displayName) - \(changeType)"
        content.body = response.explanation
        content.categoryIdentifier = "PERSISTENCE_CHANGE"
        content.userInfo = [
            "itemIdentifier": item.identifier,
            "category": item.category.rawValue,
            "severity": response.severity,
            "changeType": changeType
        ]

        // Set sound based on severity
        let severity = AISeverity(rawValue: response.severity) ?? .info
        if severity >= .high {
            content.sound = .defaultCritical
        } else if severity >= .medium {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            NSLog("[PersistenceMonitor] AI notification sent: %@", response.title)
        } catch {
            NSLog("[PersistenceMonitor] Failed to send AI notification: %@", error.localizedDescription)
        }
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
