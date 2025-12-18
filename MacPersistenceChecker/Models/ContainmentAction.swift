import Foundation
import GRDB

// MARK: - Containment Action Types

enum ContainmentActionType: String, Codable, DatabaseValueConvertible {
    case contain              // Full containment (persistence + network)
    case release              // Release from containment
    case persistenceDisable   // Only disable persistence
    case persistenceEnable    // Re-enable persistence
    case networkBlock         // Only block network
    case networkUnblock       // Unblock network
    case extendTimeout        // Extend containment timeout
}

enum ContainmentStatus: String, Codable, DatabaseValueConvertible {
    case active               // Containment is active
    case released             // Released by user
    case expired              // Auto-expired (timeout)
    case failed               // Action failed
    case partial              // Partial success (e.g., persistence disabled but network block failed)
}

// MARK: - Network Rule

struct NetworkRule: Codable, Equatable {
    let id: String                    // UUID
    let anchor: String                // "mpc/contain_<hash>"
    let binaryPath: String
    let createdAt: Date
    let expiresAt: Date?              // Timeout (default: 24h)
    let method: NetworkBlockMethod    // pfctl or socketfilterfw

    var isExpired: Bool {
        guard let expires = expiresAt else { return false }
        return Date() > expires
    }

    var timeRemaining: TimeInterval? {
        guard let expires = expiresAt else { return nil }
        return expires.timeIntervalSinceNow
    }
}

enum NetworkBlockMethod: String, Codable {
    case pfctl              // Primary: packet filter
    case socketfilterfw     // Fallback: Application Firewall
}

// MARK: - Containment State

struct ContainmentState: Codable, Equatable {
    var isContained: Bool
    var persistenceDisabled: Bool
    var networkBlocked: Bool
    var networkRule: NetworkRule?
    var binaryHash: String?
    var containedAt: Date?
    var expiresAt: Date?

    static let none = ContainmentState(
        isContained: false,
        persistenceDisabled: false,
        networkBlocked: false,
        networkRule: nil,
        binaryHash: nil,
        containedAt: nil,
        expiresAt: nil
    )

    var timeRemaining: String {
        guard let expires = expiresAt else { return "No expiration" }
        let remaining = expires.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }

        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m remaining"
        } else {
            return "\(minutes)m remaining"
        }
    }
}

// MARK: - Containment Action Record (Database)

struct ContainmentAction: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    let itemIdentifier: String
    let itemCategory: String
    let actionType: ContainmentActionType
    let timestamp: Date
    let binaryPath: String?
    let binaryHash: String?
    let plistPath: String?
    let plistBackup: String?          // Original plist content
    let networkRuleId: String?
    let networkAnchor: String?
    let networkMethod: String?
    let status: ContainmentStatus
    let expiresAt: Date?
    let details: String?              // JSON for additional info

    static var databaseTableName: String { "containmentActions" }

    enum Columns: String, ColumnExpression {
        case id, itemIdentifier, itemCategory, actionType, timestamp
        case binaryPath, binaryHash, plistPath, plistBackup
        case networkRuleId, networkAnchor, networkMethod
        case status, expiresAt, details
    }

    // MARK: - Factory Methods

    static func contain(
        item: PersistenceItem,
        binaryHash: String?,
        plistBackup: String?,
        networkRule: NetworkRule?,
        expiresAt: Date?,
        status: ContainmentStatus = .active,
        details: [String: Any]? = nil
    ) -> ContainmentAction {
        ContainmentAction(
            id: nil,
            itemIdentifier: item.identifier,
            itemCategory: item.category.rawValue,
            actionType: .contain,
            timestamp: Date(),
            binaryPath: item.effectiveExecutablePath?.path,
            binaryHash: binaryHash,
            plistPath: item.plistPath?.path,
            plistBackup: plistBackup,
            networkRuleId: networkRule?.id,
            networkAnchor: networkRule?.anchor,
            networkMethod: networkRule?.method.rawValue,
            status: status,
            expiresAt: expiresAt,
            details: details.flatMap { try? JSONSerialization.data(withJSONObject: $0).base64EncodedString() }
        )
    }

    static func release(
        item: PersistenceItem,
        previousAction: ContainmentAction
    ) -> ContainmentAction {
        ContainmentAction(
            id: nil,
            itemIdentifier: item.identifier,
            itemCategory: item.category.rawValue,
            actionType: .release,
            timestamp: Date(),
            binaryPath: previousAction.binaryPath,
            binaryHash: previousAction.binaryHash,
            plistPath: previousAction.plistPath,
            plistBackup: nil,
            networkRuleId: previousAction.networkRuleId,
            networkAnchor: previousAction.networkAnchor,
            networkMethod: previousAction.networkMethod,
            status: .released,
            expiresAt: nil,
            details: nil
        )
    }

    static func networkBlock(
        item: PersistenceItem,
        networkRule: NetworkRule,
        expiresAt: Date?,
        status: ContainmentStatus = .active
    ) -> ContainmentAction {
        ContainmentAction(
            id: nil,
            itemIdentifier: item.identifier,
            itemCategory: item.category.rawValue,
            actionType: .networkBlock,
            timestamp: Date(),
            binaryPath: item.effectiveExecutablePath?.path,
            binaryHash: nil,
            plistPath: nil,
            plistBackup: nil,
            networkRuleId: networkRule.id,
            networkAnchor: networkRule.anchor,
            networkMethod: networkRule.method.rawValue,
            status: status,
            expiresAt: expiresAt,
            details: nil
        )
    }

    static func persistenceDisable(
        item: PersistenceItem,
        plistBackup: String?,
        status: ContainmentStatus = .active
    ) -> ContainmentAction {
        ContainmentAction(
            id: nil,
            itemIdentifier: item.identifier,
            itemCategory: item.category.rawValue,
            actionType: .persistenceDisable,
            timestamp: Date(),
            binaryPath: item.effectiveExecutablePath?.path,
            binaryHash: nil,
            plistPath: item.plistPath?.path,
            plistBackup: plistBackup,
            networkRuleId: nil,
            networkAnchor: nil,
            networkMethod: nil,
            status: status,
            expiresAt: nil,
            details: nil
        )
    }

    // MARK: - Helpers

    var decodedDetails: [String: Any]? {
        guard let details = details,
              let data = Data(base64Encoded: details),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    var displayDescription: String {
        switch actionType {
        case .contain:
            return "Full containment applied"
        case .release:
            return "Released from containment"
        case .persistenceDisable:
            return "Persistence disabled"
        case .persistenceEnable:
            return "Persistence re-enabled"
        case .networkBlock:
            return "Network blocked"
        case .networkUnblock:
            return "Network unblocked"
        case .extendTimeout:
            return "Timeout extended"
        }
    }

    var statusColor: String {
        switch status {
        case .active: return "orange"
        case .released: return "green"
        case .expired: return "gray"
        case .failed: return "red"
        case .partial: return "yellow"
        }
    }
}

// MARK: - Containment Result

struct ContainmentResult {
    let success: Bool
    let action: ContainmentAction?
    let error: ContainmentError?
    let warnings: [String]

    static func success(_ action: ContainmentAction, warnings: [String] = []) -> ContainmentResult {
        ContainmentResult(success: true, action: action, error: nil, warnings: warnings)
    }

    static func failure(_ error: ContainmentError) -> ContainmentResult {
        ContainmentResult(success: false, action: nil, error: error, warnings: [])
    }

    static func partial(_ action: ContainmentAction, error: ContainmentError, warnings: [String] = []) -> ContainmentResult {
        ContainmentResult(success: false, action: action, error: error, warnings: warnings)
    }
}

enum ContainmentError: Error, LocalizedError {
    case itemNotFound
    case plistNotFound
    case binaryNotFound
    case permissionDenied
    case pfctlFailed(String)
    case socketFilterFailed(String)
    case launchctlFailed(String)
    case fileOperationFailed(String)
    case databaseError(String)
    case alreadyContained
    case notContained
    case hashMismatch(expected: String, actual: String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Item not found"
        case .plistNotFound:
            return "Plist file not found"
        case .binaryNotFound:
            return "Binary file not found"
        case .permissionDenied:
            return "Permission denied - administrator privileges required"
        case .pfctlFailed(let msg):
            return "pfctl failed: \(msg)"
        case .socketFilterFailed(let msg):
            return "Application Firewall failed: \(msg)"
        case .launchctlFailed(let msg):
            return "launchctl failed: \(msg)"
        case .fileOperationFailed(let msg):
            return "File operation failed: \(msg)"
        case .databaseError(let msg):
            return "Database error: \(msg)"
        case .alreadyContained:
            return "Item is already contained"
        case .notContained:
            return "Item is not contained"
        case .hashMismatch(let expected, let actual):
            return "Binary hash mismatch - expected: \(expected.prefix(16))..., actual: \(actual.prefix(16))..."
        case .unknown(let msg):
            return "Unknown error: \(msg)"
        }
    }
}
