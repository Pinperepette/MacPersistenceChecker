import Foundation

/// Trigger che ha causato la creazione dello snapshot
enum SnapshotTrigger: String, Codable, CaseIterable {
    case firstLaunch = "first_launch"
    case userLogin = "user_login"
    case appUpdate = "app_update"
    case manual = "manual"
    case scheduled = "scheduled"

    var displayName: String {
        switch self {
        case .firstLaunch: return "First Launch"
        case .userLogin: return "User Login"
        case .appUpdate: return "App Update"
        case .manual: return "Manual"
        case .scheduled: return "Scheduled"
        }
    }

    var symbolName: String {
        switch self {
        case .firstLaunch: return "star.fill"
        case .userLogin: return "person.fill"
        case .appUpdate: return "arrow.down.app.fill"
        case .manual: return "hand.tap.fill"
        case .scheduled: return "clock.fill"
        }
    }
}

/// Rappresenta uno snapshot del sistema in un momento specifico
struct Snapshot: Identifiable, Codable, Equatable {
    /// Unique identifier
    let id: UUID

    /// When the snapshot was created
    let createdAt: Date

    /// What triggered the snapshot
    let trigger: SnapshotTrigger

    /// Optional user note
    let note: String?

    /// Number of items in this snapshot
    let itemCount: Int

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        trigger: SnapshotTrigger,
        note: String? = nil,
        itemCount: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.trigger = trigger
        self.note = note
        self.itemCount = itemCount
    }

    /// Formatted date string
    var displayDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    /// Relative date string (e.g., "2 hours ago")
    var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: createdAt, relativeTo: Date())
    }

    /// Short identifier for display
    var shortId: String {
        String(id.uuidString.prefix(8))
    }
}

/// Item salvato in uno snapshot (versione serializzabile)
struct SnapshotItem: Codable, Equatable {
    let snapshotId: UUID
    let itemId: UUID
    let identifier: String
    let category: PersistenceCategory
    let name: String
    let plistPath: String?
    let executablePath: String?
    let trustLevel: TrustLevel
    let isEnabled: Bool
    let isLoaded: Bool
    let signatureInfoJSON: String?
    let bundleIdentifier: String?
    let teamIdentifier: String?
    let programArguments: [String]?
    let runAtLoad: Bool?
    let keepAlive: Bool?
    let plistModifiedAt: Date?
    let binaryModifiedAt: Date?

    init(snapshotId: UUID, item: PersistenceItem) {
        self.snapshotId = snapshotId
        self.itemId = item.id
        self.identifier = item.identifier
        self.category = item.category
        self.name = item.name
        self.plistPath = item.plistPath?.path
        self.executablePath = item.executablePath?.path
        self.trustLevel = item.trustLevel
        self.isEnabled = item.isEnabled
        self.isLoaded = item.isLoaded
        self.bundleIdentifier = item.bundleIdentifier
        self.teamIdentifier = item.signatureInfo?.teamIdentifier
        self.programArguments = item.programArguments
        self.runAtLoad = item.runAtLoad
        self.keepAlive = item.keepAlive
        self.plistModifiedAt = item.plistModifiedAt
        self.binaryModifiedAt = item.binaryModifiedAt

        // Encode signature info as JSON
        if let sigInfo = item.signatureInfo {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(sigInfo) {
                self.signatureInfoJSON = String(data: data, encoding: .utf8)
            } else {
                self.signatureInfoJSON = nil
            }
        } else {
            self.signatureInfoJSON = nil
        }
    }

    /// Convert back to PersistenceItem
    func toPersistenceItem() -> PersistenceItem {
        var signatureInfo: SignatureInfo?
        if let json = signatureInfoJSON,
           let data = json.data(using: .utf8) {
            signatureInfo = try? JSONDecoder().decode(SignatureInfo.self, from: data)
        }

        return PersistenceItem(
            id: itemId,
            identifier: identifier,
            category: category,
            name: name,
            plistPath: plistPath.map { URL(fileURLWithPath: $0) },
            executablePath: executablePath.map { URL(fileURLWithPath: $0) },
            trustLevel: trustLevel,
            signatureInfo: signatureInfo,
            isEnabled: isEnabled,
            isLoaded: isLoaded,
            programArguments: programArguments,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            bundleIdentifier: bundleIdentifier,
            plistModifiedAt: plistModifiedAt,
            binaryModifiedAt: binaryModifiedAt
        )
    }
}
