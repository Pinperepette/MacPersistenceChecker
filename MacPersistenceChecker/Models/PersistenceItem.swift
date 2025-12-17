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

    // MARK: - Timestamps & Forensics

    /// When the plist file was created
    var plistCreatedAt: Date?

    /// When the plist was last modified
    var plistModifiedAt: Date?

    /// When the binary file was created
    var binaryCreatedAt: Date?

    /// When the binary was last modified
    var binaryModifiedAt: Date?

    /// When the binary was last accessed/executed
    var binaryLastExecutedAt: Date?

    /// When this item was first discovered by our app
    var discoveredAt: Date

    /// When we first saw network activity from this item
    var networkFirstSeenAt: Date?

    /// When we last saw network activity from this item
    var networkLastSeenAt: Date?

    // MARK: - Risk Assessment

    /// Risk score (0-100, higher = more suspicious)
    var riskScore: Int?

    /// Detailed risk factors
    var riskDetails: [RiskScorer.RiskDetail]?

    // MARK: - Signed-but-Dangerous Analysis

    /// Signed-but-Dangerous analysis flags
    var signedButDangerousFlags: [SignedButDangerousFlag]?

    /// Overall signed-but-dangerous risk level
    var signedButDangerousRisk: String?

    /// Simple flag representation for Codable
    struct SignedButDangerousFlag: Codable, Identifiable, Hashable {
        let id: UUID
        let type: String
        let title: String
        let description: String
        let points: Int
        let severity: String

        init(from flag: SignedButDangerousAnalyzer.DangerFlag) {
            self.id = flag.id
            self.type = flag.type.rawValue
            self.title = flag.title
            self.description = flag.description
            self.points = flag.points
            self.severity = flag.severity.rawValue
        }

        init(id: UUID = UUID(), type: String, title: String, description: String, points: Int, severity: String) {
            self.id = id
            self.type = type
            self.title = title
            self.description = description
            self.points = points
            self.severity = severity
        }
    }

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
        plistCreatedAt: Date? = nil,
        plistModifiedAt: Date? = nil,
        binaryCreatedAt: Date? = nil,
        binaryModifiedAt: Date? = nil,
        binaryLastExecutedAt: Date? = nil,
        discoveredAt: Date = Date(),
        networkFirstSeenAt: Date? = nil,
        networkLastSeenAt: Date? = nil,
        riskScore: Int? = nil,
        riskDetails: [RiskScorer.RiskDetail]? = nil
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
        self.plistCreatedAt = plistCreatedAt
        self.plistModifiedAt = plistModifiedAt
        self.binaryCreatedAt = binaryCreatedAt
        self.binaryModifiedAt = binaryModifiedAt
        self.binaryLastExecutedAt = binaryLastExecutedAt
        self.discoveredAt = discoveredAt
        self.networkFirstSeenAt = networkFirstSeenAt
        self.networkLastSeenAt = networkLastSeenAt
        self.riskScore = riskScore
        self.riskDetails = riskDetails
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
        // Sort by risk score (higher risk first), then by trust level, then by name
        let lhsRisk = lhs.riskScore ?? 0
        let rhsRisk = rhs.riskScore ?? 0

        if lhsRisk != rhsRisk {
            return lhsRisk > rhsRisk // Higher risk first
        }

        if lhs.trustLevel != rhs.trustLevel {
            return lhs.trustLevel < rhs.trustLevel
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

// MARK: - Risk Severity

extension PersistenceItem {
    /// Risk severity based on score
    var riskSeverity: RiskScorer.RiskSeverity {
        return .from(score: riskScore ?? 0)
    }
}
