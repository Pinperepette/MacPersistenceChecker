import Foundation

/// Risultato del confronto tra due snapshot
struct SnapshotDiff: Equatable {
    /// Source snapshot (older)
    let fromSnapshot: Snapshot

    /// Target snapshot (newer)
    let toSnapshot: Snapshot

    /// Items that were added (present in 'to' but not in 'from')
    let addedItems: [PersistenceItem]

    /// Items that were removed (present in 'from' but not in 'to')
    let removedItems: [PersistenceItem]

    /// Items that were modified
    let changedItems: [ItemChange]

    /// Whether there are any changes
    var hasChanges: Bool {
        !addedItems.isEmpty || !removedItems.isEmpty || !changedItems.isEmpty
    }

    /// Total number of changes
    var totalChanges: Int {
        addedItems.count + removedItems.count + changedItems.count
    }

    /// Human-readable summary
    var summary: String {
        var parts: [String] = []

        if !addedItems.isEmpty {
            parts.append("+\(addedItems.count) added")
        }
        if !removedItems.isEmpty {
            parts.append("-\(removedItems.count) removed")
        }
        if !changedItems.isEmpty {
            parts.append("~\(changedItems.count) changed")
        }

        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }

    /// Items grouped by change type for display
    var groupedChanges: [(title: String, items: [DiffDisplayItem])] {
        var groups: [(String, [DiffDisplayItem])] = []

        if !addedItems.isEmpty {
            let items = addedItems.map { DiffDisplayItem(item: $0, changeType: .added) }
            groups.append(("Added", items))
        }

        if !removedItems.isEmpty {
            let items = removedItems.map { DiffDisplayItem(item: $0, changeType: .removed) }
            groups.append(("Removed", items))
        }

        if !changedItems.isEmpty {
            let items = changedItems.map { DiffDisplayItem(item: $0.item, changeType: .modified, changes: $0.details) }
            groups.append(("Modified", items))
        }

        return groups
    }
}

/// Tipo di cambiamento per un item
enum ChangeType: String, Codable {
    case added
    case removed
    case modified
    case enabled
    case disabled
    case trustLevelChanged

    var displayName: String {
        switch self {
        case .added: return "Added"
        case .removed: return "Removed"
        case .modified: return "Modified"
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        case .trustLevelChanged: return "Trust Changed"
        }
    }

    var symbolName: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .enabled: return "checkmark.circle.fill"
        case .disabled: return "xmark.circle.fill"
        case .trustLevelChanged: return "shield.fill"
        }
    }
}

/// Descrive un cambiamento in un item
struct ItemChange: Equatable {
    let item: PersistenceItem
    let changeType: ChangeType
    let details: [ChangeDetail]

    var summary: String {
        if details.isEmpty {
            return changeType.displayName
        }
        return details.map { $0.shortDescription }.joined(separator: ", ")
    }
}

/// Dettaglio di un singolo cambiamento
struct ChangeDetail: Equatable {
    let field: String
    let oldValue: String
    let newValue: String

    var shortDescription: String {
        "\(field): \(oldValue) → \(newValue)"
    }
}

/// Item per visualizzazione nel diff
struct DiffDisplayItem: Identifiable {
    let id = UUID()
    let item: PersistenceItem
    let changeType: ChangeType
    let changes: [ChangeDetail]

    init(item: PersistenceItem, changeType: ChangeType, changes: [ChangeDetail] = []) {
        self.item = item
        self.changeType = changeType
        self.changes = changes
    }
}
