import Foundation
import SwiftUI
import Combine

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
    @Published var sortOrder: SortOrder = .trustLevel

    /// Current filter
    @Published var trustFilter: TrustLevel? = nil

    /// Show only enabled items
    @Published var showOnlyEnabled: Bool = false

    // MARK: - UI State

    /// Whether to show snapshots sheet
    @Published var showSnapshotsSheet: Bool = false

    /// Whether to skip FDA check (temporary)
    @Published var skipFDACheck: Bool = false

    /// Sidebar collapsed state
    @Published var sidebarCollapsed: Bool = false

    /// Detail panel collapsed state
    @Published var detailCollapsed: Bool = false

    // MARK: - Snapshots

    /// Available snapshots
    @Published var snapshots: [Snapshot] = []

    /// Current snapshot being viewed
    @Published var currentSnapshot: Snapshot? = nil

    // MARK: - Private

    private let scanner = ScannerOrchestrator()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupBindings()
        loadSnapshots()
    }

    private func setupBindings() {
        // Update filtered items when selection, search, or filter changes
        Publishers.CombineLatest4(
            $items,
            $selectedCategory,
            $searchQuery,
            $trustFilter
        )
        .combineLatest($showOnlyEnabled, $sortOrder)
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] combined in
            let ((items, category, query, trustFilter), showOnlyEnabled, sortOrder) = combined
            self?.updateFilteredItems(
                items: items,
                category: category,
                query: query,
                trustFilter: trustFilter,
                showOnlyEnabled: showOnlyEnabled,
                sortOrder: sortOrder
            )
        }
        .store(in: &cancellables)

        // Observe scanner state
        scanner.$isScanning
            .assign(to: &$isScanning)

        scanner.$progress
            .assign(to: &$scanProgress)

        scanner.$currentCategory
            .assign(to: &$currentScanCategory)
    }

    private func updateFilteredItems(
        items: [PersistenceItem],
        category: PersistenceCategory?,
        query: String,
        trustFilter: TrustLevel?,
        showOnlyEnabled: Bool,
        sortOrder: SortOrder
    ) {
        var filtered = items

        // Filter by category
        if let category = category {
            filtered = filtered.filter { $0.category == category }
        }

        // Filter by search query
        if !query.isEmpty {
            let lowercaseQuery = query.lowercased()
            filtered = filtered.filter { item in
                item.name.lowercased().contains(lowercaseQuery) ||
                item.identifier.lowercased().contains(lowercaseQuery) ||
                (item.signatureInfo?.organizationName?.lowercased().contains(lowercaseQuery) ?? false) ||
                (item.signatureInfo?.teamIdentifier?.lowercased().contains(lowercaseQuery) ?? false)
            }
        }

        // Filter by trust level
        if let trustFilter = trustFilter {
            filtered = filtered.filter { $0.trustLevel == trustFilter }
        }

        // Filter by enabled state
        if showOnlyEnabled {
            filtered = filtered.filter { $0.isEnabled }
        }

        // Sort
        filtered = sortItems(filtered, by: sortOrder)

        filteredItems = filtered
    }

    private func sortItems(_ items: [PersistenceItem], by order: SortOrder) -> [PersistenceItem] {
        switch order {
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
        let startTime = CFAbsoluteTimeGetCurrent()
        items = await scanner.scanAll()
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("⚡️ Scan completed in \(String(format: "%.2f", elapsed)) seconds - Found \(items.count) items")
        lastScanDate = Date()

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

    /// Get suspicious item count
    var suspiciousCount: Int {
        items.filter { $0.trustLevel == .unsigned || $0.trustLevel == .suspicious }.count
    }

    /// Get total item count
    var totalCount: Int {
        items.count
    }
}

// MARK: - Sort Order

enum SortOrder: String, CaseIterable, Identifiable {
    case trustLevel = "trust_level"
    case name = "name"
    case category = "category"
    case dateModified = "date_modified"
    case vendor = "vendor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trustLevel: return "Trust Level"
        case .name: return "Name"
        case .category: return "Category"
        case .dateModified: return "Date Modified"
        case .vendor: return "Vendor"
        }
    }

    var symbolName: String {
        switch self {
        case .trustLevel: return "shield"
        case .name: return "textformat"
        case .category: return "folder"
        case .dateModified: return "calendar"
        case .vendor: return "building.2"
        }
    }
}
