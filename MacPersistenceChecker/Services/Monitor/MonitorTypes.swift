import Foundation

// MARK: - Change Event Types

/// Types of file system change events from FSEvents
enum FSChangeEventType: String, Codable {
    case created
    case deleted
    case modified
    case renamed
}

/// A directory change event from FSEvents
struct DirectoryChangeEvent {
    let path: URL
    let eventType: FSChangeEventType
    let category: PersistenceCategory
    let timestamp: Date
}

// MARK: - Monitor Change Types

/// Type of persistence change detected
enum MonitorChangeType: String, Codable {
    case added
    case removed
    case modified
    case enabled
    case disabled
}

/// Detail of a specific field change in monitoring
struct MonitorChangeDetail: Codable, Equatable {
    let field: String
    let oldValue: String
    let newValue: String
}

/// A detected change in persistence state
struct MonitorChange: Identifiable, Codable {
    let id: UUID
    let type: MonitorChangeType
    let item: PersistenceItem?
    let category: PersistenceCategory
    let timestamp: Date
    let details: [MonitorChangeDetail]

    init(
        id: UUID = UUID(),
        type: MonitorChangeType,
        item: PersistenceItem?,
        category: PersistenceCategory,
        timestamp: Date = Date(),
        details: [MonitorChangeDetail] = []
    ) {
        self.id = id
        self.type = type
        self.item = item
        self.category = category
        self.timestamp = timestamp
        self.details = details
    }

    /// Human-readable summary of the change
    var summary: String {
        let itemName = item?.name ?? "Unknown"
        switch type {
        case .added:
            return "New: \(itemName)"
        case .removed:
            return "Removed: \(itemName)"
        case .modified:
            let fields = details.map { $0.field }.joined(separator: ", ")
            return "Modified: \(itemName) (\(fields))"
        case .enabled:
            return "Enabled: \(itemName)"
        case .disabled:
            return "Disabled: \(itemName)"
        }
    }
}

// MARK: - Monitor Errors

/// Errors that can occur during monitoring
enum MonitorError: Error, LocalizedError {
    case baselineNotFound
    case baselineCreationFailed(String)
    case watcherFailed(String)
    case watcherAlreadyRunning
    case notificationPermissionDenied
    case databaseError(String)
    case categoryNotEnabled
    case scanFailed(String)

    var errorDescription: String? {
        switch self {
        case .baselineNotFound:
            return "No baseline found. Please create a baseline first."
        case .baselineCreationFailed(let msg):
            return "Failed to create baseline: \(msg)"
        case .watcherFailed(let msg):
            return "Directory watcher failed: \(msg)"
        case .watcherAlreadyRunning:
            return "Monitoring is already active"
        case .notificationPermissionDenied:
            return "Notification permission was denied"
        case .databaseError(let msg):
            return "Database error: \(msg)"
        case .categoryNotEnabled:
            return "Category is not enabled for monitoring"
        case .scanFailed(let msg):
            return "Scan failed: \(msg)"
        }
    }
}

// MARK: - Monitor State

/// Current state of the monitoring system
enum MonitorState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case error(String)

    var isActive: Bool {
        switch self {
        case .running, .starting:
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting..."
        case .running:
            return "Monitoring"
        case .stopping:
            return "Stopping..."
        case .error(let msg):
            return "Error: \(msg)"
        }
    }
}

// MARK: - Baseline Item

/// A baseline item stored in database
struct BaselineItem: Codable {
    let identifier: String
    let category: String
    let itemJSON: String
    let capturedAt: Date
}

// MARK: - Change History Entry

/// A change history entry for logging
struct ChangeHistoryEntry: Identifiable, Codable {
    let id: UUID
    let changeType: MonitorChangeType
    let category: PersistenceCategory
    let itemIdentifier: String?
    let itemName: String?
    let details: [MonitorChangeDetail]
    let relevanceScore: Int
    let timestamp: Date
    var acknowledged: Bool

    init(from change: MonitorChange, relevanceScore: Int) {
        self.id = UUID()
        self.changeType = change.type
        self.category = change.category
        self.itemIdentifier = change.item?.identifier
        self.itemName = change.item?.name
        self.details = change.details
        self.relevanceScore = relevanceScore
        self.timestamp = change.timestamp
        self.acknowledged = false
    }

    init(
        id: UUID,
        changeType: MonitorChangeType,
        category: PersistenceCategory,
        itemIdentifier: String?,
        itemName: String?,
        details: [MonitorChangeDetail],
        relevanceScore: Int,
        timestamp: Date,
        acknowledged: Bool
    ) {
        self.id = id
        self.changeType = changeType
        self.category = category
        self.itemIdentifier = itemIdentifier
        self.itemName = itemName
        self.details = details
        self.relevanceScore = relevanceScore
        self.timestamp = timestamp
        self.acknowledged = acknowledged
    }
}
