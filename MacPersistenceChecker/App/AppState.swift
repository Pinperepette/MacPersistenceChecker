import Foundation
import SwiftUI
import Combine

// Debug helper
extension String {
    func appendToFile(_ path: String) throws {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(self.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try self.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// Global application state
@MainActor
final class AppState: ObservableObject {
    /// Shared instance
    static let shared = AppState()

    // MARK: - Scanning State

    /// All discovered persistence items
    @Published var items: [PersistenceItem] = []

    /// Items filtered by current selection
    @Published var filteredItems: [PersistenceItem] = []

    /// Currently selected category
    @Published var selectedCategory: PersistenceCategory? = nil

    /// Currently selected item
    @Published var selectedItem: PersistenceItem? = nil

    /// Whether a scan is in progress
    @Published var isScanning: Bool = false

    /// Current scan progress
    @Published var scanProgress: Double = 0

    /// Currently scanning category
    @Published var currentScanCategory: PersistenceCategory? = nil

    /// Last scan date
    @Published var lastScanDate: Date? = nil

    // MARK: - Search & Filter

    /// Search query
    @Published var searchQuery: String = ""

    /// Current sort order
    @Published var sortOrder: SortOrder = .riskScore

    /// Current filter
    @Published var trustFilter: TrustLevel? = nil

    /// Show only enabled items
    @Published var showOnlyEnabled: Bool = false

    /// Hide items the knowledge graph has classified as benign with high confidence.
    /// Default off — the user opts in via the eye toggle. With a dense graph
    /// (thousands of accumulated rules) the auto-hide can wipe out almost every
    /// item, leaving the user staring at a near-empty list at launch.
    @Published var hideGraphTrusted: Bool = UserDefaults.standard.object(forKey: "hideGraphTrusted") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(hideGraphTrusted, forKey: "hideGraphTrusted")
            refreshFilter()
        }
    }

    // MARK: - UI State

    /// Whether to show snapshots sheet
    @Published var showSnapshotsSheet: Bool = false

    /// Whether to skip FDA check (persisted - survives app restarts)
    @AppStorage("skipFDACheck") var skipFDACheck: Bool = false

    /// Sidebar collapsed state
    @Published var sidebarCollapsed: Bool = false

    /// Detail panel collapsed state
    @Published var detailCollapsed: Bool = false

    /// Item to show in focused graph view (nil = show full graph)
    @Published var focusedGraphItem: PersistenceItem? = nil

    // MARK: - Graph Detail Window

    /// Node to show in detail window
    @Published var graphDetailNode: GraphNode? = nil

    /// Edge to show in detail window
    @Published var graphDetailEdge: GraphEdge? = nil

    /// Source node for edge detail
    @Published var graphDetailSourceNode: GraphNode? = nil

    /// Target node for edge detail
    @Published var graphDetailTargetNode: GraphNode? = nil

    /// Persistence item for detailed view (linked from node)
    @Published var graphDetailPersistenceItem: PersistenceItem? = nil

    // MARK: - Snapshots

    /// Available snapshots
    @Published var snapshots: [Snapshot] = []

    /// Current snapshot being viewed
    @Published var currentSnapshot: Snapshot? = nil

    // MARK: - Monitoring State

    /// Whether real-time monitoring is active
    @Published var isMonitoring: Bool = false

    /// Last detected change from monitor
    @Published var lastMonitorChange: MonitorChange? = nil

    /// Count of unacknowledged changes
    @Published var unacknowledgedChangeCount: Int = 0

    // MARK: - Private

    private let scanner = ScannerOrchestrator()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Ensure database is initialized before we try to load from it
        ensureDatabaseInitialized()
        setupBindings()
        // Heavy DB reads (snapshots, cached scan with 6800+ JSON-decoded items)
        // run off the main thread so the UI can show the chrome immediately.
        // The @Published assignments hop back to main when the data is ready.
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.loadSnapshotsAsync()
            await self?.loadCachedScanAsync()
        }
        // Pre-warm the knowledge-graph rule cache + concept cache off the main
        // thread so the first filter / eye-toggle never blocks on SQLite.
        RuleMatcher.shared.preload()
        ConceptStore.shared.preload()
        // Note: Containment and Monitor are initialized lazily to avoid permission prompts on launch
    }

    /// Ensure database is initialized (idempotent)
    private func ensureDatabaseInitialized() {
        if DatabaseManager.shared.dbQueue == nil {
            do {
                try DatabaseManager.shared.initialize()
                NSLog("[AppState] Database initialized")
            } catch {
                NSLog("[AppState] Failed to initialize database: %@", error.localizedDescription)
            }
        } else {
            NSLog("[AppState] Database already initialized")
        }
    }

    /// Load cached scan results from database
    private func loadCachedScan() {
        NSLog("[AppState] Loading cached scan...")
        do {
            if let cached = try DatabaseManager.shared.loadLastScan() {
                items = cached.items
                lastScanDate = cached.scanDate
                NSLog("[AppState] Loaded %d items from cache", cached.items.count)
            } else {
                NSLog("[AppState] No cached scan found")
            }
        } catch {
            NSLog("[AppState] Failed to load cached scan: %@", error.localizedDescription)
        }
    }

    /// Async variant: reads + JSON-decodes the cached scan off the main thread
    /// (6800+ PersistenceItems is 300-800ms of decode work). The @Published
    /// assignment hops back to the main actor; the UI sees a single state
    /// transition once everything is ready, with no main-thread freeze.
    private func loadCachedScanAsync() async {
        NSLog("[AppState] Loading cached scan (async)...")
        let cached = await Task.detached(priority: .userInitiated) {
            do {
                return try DatabaseManager.shared.loadLastScan()
            } catch {
                NSLog("[AppState] Failed to load cached scan: %@", error.localizedDescription)
                return nil
            }
        }.value

        guard let cached else {
            NSLog("[AppState] No cached scan found")
            return
        }

        await MainActor.run { [weak self] in
            self?.items = cached.items
            self?.lastScanDate = cached.scanDate
            NSLog("[AppState] Loaded %d items from cache", cached.items.count)
        }

        // Kick off concept ingest in the background so the resolver has
        // associations available before the user opens Smart Triage.
        let snapshot = cached.items
        Task.detached(priority: .utility) { [weak self] in
            _ = await ConceptIngestor.shared.ingest(items: snapshot)
            await MainActor.run { self?.refreshFilter() }
        }
    }

    /// Async variant of loadSnapshots for the same reason as loadCachedScanAsync.
    private func loadSnapshotsAsync() async {
        let snapshots: [Snapshot] = await Task.detached(priority: .userInitiated) {
            (try? DatabaseManager.shared.getAllSnapshots()) ?? []
        }.value
        await MainActor.run { [weak self] in
            self?.snapshots = snapshots
        }
    }

    /// Trigger that fires when something outside the @Published chain
    /// requests a filter refresh (e.g. after a Trust action mutates the
    /// knowledge graph but the items themselves haven't changed). Subscribed
    /// to in `setupBindings` so manual refreshes go through the same off-main
    /// pipeline as automatic ones.
    private let manualRefreshSubject = PassthroughSubject<Void, Never>()

    /// Inputs to a single filter pass. Bundled so we can pass a Sendable value
    /// across thread boundaries without dragging AppState.
    private struct FilterInputs {
        let items: [PersistenceItem]
        let category: PersistenceCategory?
        let query: String
        let trustFilter: TrustLevel?
        let showOnlyEnabled: Bool
        let sortOrder: SortOrder
        let hideGraphTrusted: Bool
    }

    /// Output of `Self.computeFilter`. Light value type, safe to pass to main.
    private struct FilterResult {
        let items: [PersistenceItem]
        let hiddenCount: Int
        let suspiciousCount: Int
    }

    private func setupBindings() {
        // Combine all filter inputs into a single trigger. We stay on the main
        // queue here (so SwiftUI's binding semantics are not perturbed) and
        // do the heavy filter work inside the sink, on a detached background
        // task. The sink itself is light — just snapshots inputs and dispatches.
        Publishers.CombineLatest4($items, $selectedCategory, $searchQuery, $trustFilter)
            .combineLatest($showOnlyEnabled, $sortOrder)
            .combineLatest($hideGraphTrusted)
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] combined in
                let (((items, cat, query, trust), showOnly, order), hideTrust) = combined
                let inputs = FilterInputs(
                    items: items,
                    category: cat,
                    query: query,
                    trustFilter: trust,
                    showOnlyEnabled: showOnly,
                    sortOrder: order,
                    hideGraphTrusted: hideTrust
                )
                self?.scheduleFilter(inputs: inputs)
            }
            .store(in: &cancellables)

        // Manual refresh fires from refreshFilter() — same path as automatic
        // emissions so the filter is computed off main here too.
        manualRefreshSubject
            .sink { [weak self] _ in
                guard let self else { return }
                let inputs = FilterInputs(
                    items: self.items,
                    category: self.selectedCategory,
                    query: self.searchQuery,
                    trustFilter: self.trustFilter,
                    showOnlyEnabled: self.showOnlyEnabled,
                    sortOrder: self.sortOrder,
                    hideGraphTrusted: self.hideGraphTrusted
                )
                self.scheduleFilter(inputs: inputs)
            }
            .store(in: &cancellables)

        // Observe scanner state
        scanner.$isScanning.assign(to: &$isScanning)
        scanner.$progress.assign(to: &$scanProgress)
        scanner.$currentCategory.assign(to: &$currentScanCategory)
    }

    /// Bookkeeping for filter scheduling: only one filter task runs at a time.
    /// If a new emission arrives while one is in flight, the previous task is
    /// cancelled so we don't waste CPU on stale inputs.
    private var pendingFilterTask: Task<Void, Never>?

    private func scheduleFilter(inputs: FilterInputs) {
        pendingFilterTask?.cancel()
        pendingFilterTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let result = AppState.computeFilter(inputs: inputs)
            guard !Task.isCancelled else { return }
            let appState = self
            await MainActor.run {
                appState?.filteredItems = result.items
                appState?.trustedHiddenCount = result.hiddenCount
                appState?.suspiciousCount = result.suspiciousCount
            }
        }
    }

    /// Pure, thread-safe filter computation. Lives off-main; the result is
    /// pushed to @Published on main by the Combine sink in `setupBindings`.
    /// Reads from globally-thread-safe singletons (ConceptIngestor /
    /// ConceptResolver / RuleMatcher all use NSLock-protected caches).
    /// `nonisolated` because we explicitly call it from a detached Task.
    private nonisolated static func computeFilter(inputs: FilterInputs) -> FilterResult {
        var filtered = inputs.items

        if let category = inputs.category {
            filtered = filtered.filter { $0.category == category }
        }

        if !inputs.query.isEmpty {
            let lq = inputs.query.lowercased()
            filtered = filtered.filter { item in
                item.name.lowercased().contains(lq) ||
                item.identifier.lowercased().contains(lq) ||
                (item.signatureInfo?.organizationName?.lowercased().contains(lq) ?? false) ||
                (item.signatureInfo?.teamIdentifier?.lowercased().contains(lq) ?? false)
            }
        }

        if let trustFilter = inputs.trustFilter {
            // Apply local trust filter, but exclude items the graph has
            // already classified as benign — once the user/AI has verified
            // an unsigned dylib is OK, it shouldn't keep appearing in the
            // "Suspicious" red list.
            filtered = filtered.filter { item in
                guard item.trustLevel == trustFilter else { return false }
                let fingerprint = ItemFingerprint.make(from: item).hash
                let conceptIDs = ConceptIngestor.shared.conceptIDs(forFingerprint: fingerprint)
                let resolved = ConceptResolver.shared.resolve(item: item, linkedConceptIDs: conceptIDs)
                if case .classified(let verdict, _) = resolved.outcome, verdict == .benign {
                    return false
                }
                if case .knownBenign(_, let conf) = RuleMatcher.shared.evaluate(item: item), conf >= 0.7 {
                    return false
                }
                return true
            }
        }

        if inputs.showOnlyEnabled {
            filtered = filtered.filter { $0.isEnabled }
        }

        var hiddenCount = 0
        if inputs.hideGraphTrusted {
            filtered = filtered.filter { item in
                let fingerprint = ItemFingerprint.make(from: item).hash
                let conceptIDs = ConceptIngestor.shared.conceptIDs(forFingerprint: fingerprint)
                let resolved = ConceptResolver.shared.resolve(item: item, linkedConceptIDs: conceptIDs)
                if case .classified(let verdict, _) = resolved.outcome, verdict == .benign {
                    hiddenCount += 1
                    return false
                }
                if case .knownBenign(_, let conf) = RuleMatcher.shared.evaluate(item: item), conf >= 0.7 {
                    hiddenCount += 1
                    return false
                }
                return true
            }
        }

        filtered = sortItems(filtered, by: inputs.sortOrder)

        // Suspicious count over the FULL items list (not just filtered) and
        // graph-aware: an unsigned item that the knowledge graph trusts as
        // benign is excluded from the count.
        let suspicious = inputs.items.reduce(into: 0) { acc, item in
            guard item.trustLevel == .unsigned || item.trustLevel == .suspicious else { return }
            let fingerprint = ItemFingerprint.make(from: item).hash
            let conceptIDs = ConceptIngestor.shared.conceptIDs(forFingerprint: fingerprint)
            let resolved = ConceptResolver.shared.resolve(item: item, linkedConceptIDs: conceptIDs)
            if case .classified(let verdict, _) = resolved.outcome, verdict == .benign {
                return
            }
            if case .knownBenign(_, let conf) = RuleMatcher.shared.evaluate(item: item), conf >= 0.7 {
                return
            }
            acc += 1
        }

        return FilterResult(items: filtered, hiddenCount: hiddenCount, suspiciousCount: suspicious)
    }

    /// Re-runs the filter pipeline through the off-main path, without waiting
    /// for an @Published change. Call this after knowledge-graph mutations.
    func refreshFilter() {
        manualRefreshSubject.send(())
    }

    /// Items hidden by the knowledge-graph filter, populated by the filter
    /// sink. Stored (not computed) so SwiftUI body recomputes don't trigger
    /// re-iteration.
    @Published private(set) var trustedHiddenCount: Int = 0

    private nonisolated static func sortItems(_ items: [PersistenceItem], by order: SortOrder) -> [PersistenceItem] {
        switch order {
        case .riskScore:
            return items.sorted { ($0.riskScore ?? 0) > ($1.riskScore ?? 0) }
        case .trustLevel:
            return items.sorted { $0.trustLevel < $1.trustLevel }
        case .name:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .category:
            return items.sorted { $0.category.displayName < $1.category.displayName }
        case .dateModified:
            return items.sorted {
                ($0.plistModifiedAt ?? .distantPast) > ($1.plistModifiedAt ?? .distantPast)
            }
        case .vendor:
            return items.sorted {
                ($0.signatureInfo?.organizationName ?? "zzz").localizedCaseInsensitiveCompare(
                    $1.signatureInfo?.organizationName ?? "zzz"
                ) == .orderedAscending
            }
        }
    }

    // MARK: - Public Methods

    /// Scan all categories
    func scanAll() async {
        let debugFile = "/tmp/mpc_scan_debug.log"
        try? "Scan started at \(Date())\n".write(toFile: debugFile, atomically: true, encoding: .utf8)

        // Clear previous results to show we're starting fresh
        items = []
        selectedItem = nil

        let startTime = CFAbsoluteTimeGetCurrent()
        items = await scanner.scanAll()
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        lastScanDate = Date()

        try? "Scan completed: \(items.count) items in \(elapsed)s\n".appendToFile(debugFile)

        // Save to cache for next app launch
        do {
            try? "Saving to cache...\n".appendToFile(debugFile)
            try DatabaseManager.shared.saveLastScan(items: items, scanDate: lastScanDate!)
            try? "Cache saved OK!\n".appendToFile(debugFile)
        } catch {
            try? "Cache save FAILED: \(error)\n".appendToFile(debugFile)
        }

        // Concept extraction over the fresh scan. Off-main; refreshes the
        // resolver caches when done so the filter starts hiding trusted items.
        let scanned = items
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = await ConceptIngestor.shared.ingest(items: scanned)
            NSLog("[AppState] Concept ingest: %d items, %d associations, %d edges in %.2fs",
                  result.itemsScanned, result.associations, result.edgesCreated, result.elapsed)
            await MainActor.run {
                self?.refreshFilter()
            }
        }

        // Create automatic snapshot if first scan
        if snapshots.isEmpty {
            await createSnapshot(trigger: .firstLaunch)
        }
    }

    /// Scan a specific category
    func scan(category: PersistenceCategory) async {
        let newItems = await scanner.scan(category: category)

        // Update items for this category
        items.removeAll { $0.category == category }
        items.append(contentsOf: newItems)
    }

    /// Create a manual snapshot
    func createManualSnapshot() async {
        await createSnapshot(trigger: .manual)
    }

    /// Create a snapshot
    func createSnapshot(trigger: SnapshotTrigger, note: String? = nil) async {
        print("📸 Creating snapshot with \(items.count) items...")

        let snapshot = Snapshot(
            trigger: trigger,
            note: note,
            itemCount: items.count
        )

        do {
            try DatabaseManager.shared.saveSnapshot(snapshot, items: items)
            loadSnapshots()
            print("✅ Snapshot saved! Total snapshots: \(snapshots.count)")
        } catch {
            print("❌ Failed to save snapshot: \(error)")
        }
    }

    /// Load snapshots from database
    func loadSnapshots() {
        do {
            let loaded = try DatabaseManager.shared.getAllSnapshots()
            let msg = "📂 Loaded \(loaded.count) snapshots from database\n"
            try? msg.write(toFile: "/tmp/mpc_debug.log", atomically: false, encoding: .utf8)
            snapshots = loaded
        } catch {
            let msg = "❌ Failed to load snapshots: \(error)\n"
            try? msg.write(toFile: "/tmp/mpc_debug.log", atomically: false, encoding: .utf8)
        }
    }

    /// Get item counts by category
    func itemCount(for category: PersistenceCategory) -> Int {
        items.filter { $0.category == category }.count
    }

    /// Number of items that are still suspicious *after* the knowledge graph
    /// has had its say. An item with an "unsigned" trust level but a benign
    /// graph verdict (e.g. a Homebrew dylib that AI/user has classified
    /// trusted) is no longer counted as suspicious — the sidebar badge would
    /// otherwise stay alarmingly high even after the graph has done its job.
    /// Refreshed by the off-main filter pipeline.
    @Published private(set) var suspiciousCount: Int = 0

    /// Get total item count
    var totalCount: Int {
        items.count
    }

    // MARK: - Monitoring Methods

    /// Whether monitor bindings have been setup
    private var monitorBindingsSetup = false

    /// Setup bindings to PersistenceMonitor (lazy - called on first monitoring access)
    private func ensureMonitorBindings() {
        guard !monitorBindingsSetup else { return }
        monitorBindingsSetup = true

        let monitor = PersistenceMonitor.shared

        // Sync monitoring state
        monitor.$state
            .map { $0 == .running }
            .receive(on: RunLoop.main)
            .assign(to: &$isMonitoring)

        // Sync last change
        monitor.$lastChange
            .receive(on: RunLoop.main)
            .assign(to: &$lastMonitorChange)

        // Sync unacknowledged count
        monitor.$unacknowledgedCount
            .receive(on: RunLoop.main)
            .assign(to: &$unacknowledgedChangeCount)
    }

    /// Toggle real-time monitoring
    func toggleMonitoring() async {
        ensureMonitorBindings()
        await PersistenceMonitor.shared.toggleMonitoring()
    }

    /// Start monitoring
    func startMonitoring() async {
        ensureMonitorBindings()
        await PersistenceMonitor.shared.startMonitoring()
    }

    /// Stop monitoring
    func stopMonitoring() {
        ensureMonitorBindings()
        PersistenceMonitor.shared.stopMonitoring()
    }

    /// Update monitoring baseline with current items
    func updateMonitorBaseline() async throws {
        ensureMonitorBindings()
        try await PersistenceMonitor.shared.updateBaseline()
    }

    /// Acknowledge all pending changes
    func acknowledgeAllChanges() {
        ensureMonitorBindings()
        PersistenceMonitor.shared.acknowledgeAllChanges()
    }

    /// Get change history
    func getChangeHistory(limit: Int = 100) -> [ChangeHistoryEntry] {
        ensureMonitorBindings()
        return PersistenceMonitor.shared.getChangeHistory(limit: limit)
    }
}

// MARK: - Sort Order

enum SortOrder: String, CaseIterable, Identifiable {
    case riskScore = "risk_score"
    case trustLevel = "trust_level"
    case name = "name"
    case category = "category"
    case dateModified = "date_modified"
    case vendor = "vendor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .riskScore: return "Risk Score"
        case .trustLevel: return "Trust Level"
        case .name: return "Name"
        case .category: return "Category"
        case .dateModified: return "Date Modified"
        case .vendor: return "Vendor"
        }
    }

    var symbolName: String {
        switch self {
        case .riskScore: return "exclamationmark.triangle"
        case .trustLevel: return "shield"
        case .name: return "textformat"
        case .category: return "folder"
        case .dateModified: return "calendar"
        case .vendor: return "building.2"
        }
    }
}
