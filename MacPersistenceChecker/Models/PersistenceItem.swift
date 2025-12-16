import Foundation

/// Modello principale per un item di persistenza
struct PersistenceItem: Identifiable, Equatable, Codable, Hashable {
    /// Unique identifier
    let id: UUID

    /// Label or bundle identifier (unique within category)
    var identifier: String

    /// Category of persistence mechanism
    let category: PersistenceCategory

    /// Display name
    var name: String

    // MARK: - Paths

    /// Path to the plist file (for LaunchDaemons/Agents, Kexts)
    var plistPath: URL?

    /// Path to the executable binary
    var executablePath: URL?

    // MARK: - Trust

    /// Computed trust level
    var trustLevel: TrustLevel

    /// Code signature information
    var signatureInfo: SignatureInfo?

    // MARK: - State

    /// Whether the item is enabled (plist exists in active location)
    var isEnabled: Bool

    /// Whether the item is currently loaded (for LaunchDaemons/Agents)
    var isLoaded: Bool

    // MARK: - Plist Content (for LaunchDaemons/Agents)

    /// Program arguments from plist
    var programArguments: [String]?

    /// RunAtLoad flag
    var runAtLoad: Bool?

    /// KeepAlive flag
    var keepAlive: Bool?

    /// Working directory
    var workingDirectory: String?

    /// Environment variables
    var environmentVariables: [String: String]?

    /// Standard output path
    var standardOutPath: String?

    /// Standard error path
    var standardErrorPath: String?

    // MARK: - Metadata

    /// Bundle identifier if different from identifier
    var bundleIdentifier: String?

    /// Version string
    var version: String?

    /// Path to the installer that installed this item (best effort)
    var installerPath: URL?

    /// Parent application path
    var parentAppPath: URL?

    // MARK: - Timestamps

    /// When the plist was last modified
    var plistModifiedAt: Date?

    /// When the binary was last modified
    var binaryModifiedAt: Date?

    /// When this item was first discovered
    var discoveredAt: Date

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        identifier: String,
        category: PersistenceCategory,
        name: String,
        plistPath: URL? = nil,
        executablePath: URL? = nil,
        trustLevel: TrustLevel = .unsigned,
        signatureInfo: SignatureInfo? = nil,
        isEnabled: Bool = true,
        isLoaded: Bool = false,
        programArguments: [String]? = nil,
        runAtLoad: Bool? = nil,
        keepAlive: Bool? = nil,
        workingDirectory: String? = nil,
        environmentVariables: [String: String]? = nil,
        standardOutPath: String? = nil,
        standardErrorPath: String? = nil,
        bundleIdentifier: String? = nil,
        version: String? = nil,
        installerPath: URL? = nil,
        parentAppPath: URL? = nil,
        plistModifiedAt: Date? = nil,
        binaryModifiedAt: Date? = nil,
        discoveredAt: Date = Date()
    ) {
        self.id = id
        self.identifier = identifier
        self.category = category
        self.name = name
        self.plistPath = plistPath
        self.executablePath = executablePath
        self.trustLevel = trustLevel
        self.signatureInfo = signatureInfo
        self.isEnabled = isEnabled
        self.isLoaded = isLoaded
        self.programArguments = programArguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.workingDirectory = workingDirectory
        self.environmentVariables = environmentVariables
        self.standardOutPath = standardOutPath
        self.standardErrorPath = standardErrorPath
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.installerPath = installerPath
        self.parentAppPath = parentAppPath
        self.plistModifiedAt = plistModifiedAt
        self.binaryModifiedAt = binaryModifiedAt
        self.discoveredAt = discoveredAt
    }

    // MARK: - Computed Properties

    /// The effective executable path (from Program or ProgramArguments[0])
    var effectiveExecutablePath: URL? {
        if let path = executablePath {
            return path
        }
        if let args = programArguments, let first = args.first {
            return URL(fileURLWithPath: first)
        }
        return nil
    }

    /// Whether this is a system (Apple) item based on path
    var isSystemItem: Bool {
        guard let path = plistPath?.path ?? executablePath?.path else {
            return false
        }
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/")
    }

    /// Whether the plist/config file exists
    var configFileExists: Bool {
        guard let path = plistPath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Whether the executable exists
    var executableExists: Bool {
        guard let path = effectiveExecutablePath else { return false }
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Short description for list view
    var shortDescription: String {
        if let org = signatureInfo?.organizationName {
            return org
        }
        if let teamId = signatureInfo?.teamIdentifier {
            return "Team: \(teamId)"
        }
        if isSystemItem {
            return "System"
        }
        return category.displayName
    }
}

// MARK: - Hashable

extension PersistenceItem {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Comparable

extension PersistenceItem: Comparable {
    static func < (lhs: PersistenceItem, rhs: PersistenceItem) -> Bool {
        // Sort by trust level (suspicious first), then by name
        if lhs.trustLevel != rhs.trustLevel {
            return lhs.trustLevel < rhs.trustLevel
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
