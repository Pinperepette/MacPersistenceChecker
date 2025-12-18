import Foundation

/// Manages baseline storage and retrieval per category
final class MonitorBaseline {
    static let shared = MonitorBaseline()

    private let db: DatabaseManager

    // MARK: - Computed Properties

    /// Whether a baseline exists
    var hasBaseline: Bool {
        (try? db.hasBaseline()) ?? false
    }

    /// When the baseline was created
    var baselineDate: Date? {
        try? db.getBaselineDate()
    }

    // MARK: - Initialization

    private init(db: DatabaseManager = .shared) {
        self.db = db
    }

    // MARK: - Public Methods

    /// Create initial baseline from current items
    func createBaseline(from items: [PersistenceItem]) throws {
        // Group by category
        let grouped = Dictionary(grouping: items) { $0.category }

        for (category, categoryItems) in grouped {
            try db.saveBaseline(items: categoryItems, for: category)
        }

        print("[MonitorBaseline] Created baseline with \(items.count) items across \(grouped.count) categories")
    }

    /// Update baseline for all categories with new items
    func updateBaseline(from items: [PersistenceItem]) throws {
        // Clear existing and create new
        try db.clearBaseline()
        try createBaseline(from: items)
    }

    /// Update baseline for a specific category only
    func updateBaseline(items: [PersistenceItem], for category: PersistenceCategory) throws {
        let categoryItems = items.filter { $0.category == category }
        try db.saveBaseline(items: categoryItems, for: category)
        print("[MonitorBaseline] Updated baseline for \(category.displayName) with \(categoryItems.count) items")
    }

    /// Get baseline items for a specific category
    func getBaseline(for category: PersistenceCategory) throws -> [PersistenceItem] {
        return try db.getBaseline(for: category)
    }

    /// Get all baseline items
    func getAllBaseline() throws -> [PersistenceItem] {
        var allItems: [PersistenceItem] = []

        for category in PersistenceCategory.allCases {
            let items = try db.getBaseline(for: category)
            allItems.append(contentsOf: items)
        }

        return allItems
    }

    /// Reset all baseline data
    func reset() throws {
        try db.clearBaseline()
        print("[MonitorBaseline] Baseline cleared")
    }

    /// Check if baseline exists for a specific category
    func hasBaseline(for category: PersistenceCategory) -> Bool {
        guard let items = try? db.getBaseline(for: category) else {
            return false
        }
        return !items.isEmpty
    }

    // MARK: - Comparison Helpers

    /// Get identifiers in baseline for a category
    func getBaselineIdentifiers(for category: PersistenceCategory) throws -> Set<String> {
        let items = try getBaseline(for: category)
        return Set(items.map { $0.identifier })
    }

    /// Quick check if an identifier exists in baseline
    func containsInBaseline(identifier: String, category: PersistenceCategory) -> Bool {
        guard let items = try? getBaseline(for: category) else {
            return false
        }
        return items.contains { $0.identifier == identifier }
    }
}

// MARK: - Baseline Statistics

extension MonitorBaseline {
    /// Statistics about the current baseline
    struct BaselineStats {
        let totalItems: Int
        let categoryCounts: [PersistenceCategory: Int]
        let createdAt: Date?

        var isEmpty: Bool {
            totalItems == 0
        }
    }

    /// Get statistics about the current baseline
    func getStats() -> BaselineStats {
        var categoryCounts: [PersistenceCategory: Int] = [:]
        var total = 0

        for category in PersistenceCategory.allCases {
            if let items = try? db.getBaseline(for: category) {
                categoryCounts[category] = items.count
                total += items.count
            }
        }

        return BaselineStats(
            totalItems: total,
            categoryCounts: categoryCounts,
            createdAt: baselineDate
        )
    }
}
