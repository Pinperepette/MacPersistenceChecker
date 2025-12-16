import Foundation

/// Database di vendor noti e fidati
final class KnownVendorsDatabase {
    /// Shared instance
    static let shared = KnownVendorsDatabase()

    /// Known vendors by team ID
    private var vendors: [String: VendorInfo] = [:]

    private init() {
        loadBuiltInVendors()
        loadUserVendors()
    }

    /// Check if a team ID belongs to a known vendor
    func isKnownVendor(teamId: String) -> Bool {
        vendors[teamId] != nil
    }

    /// Get vendor info for a team ID
    func getVendor(teamId: String) -> VendorInfo? {
        vendors[teamId]
    }

    /// Get vendor name for a team ID
    func getVendorName(teamId: String) -> String? {
        vendors[teamId]?.name
    }

    /// Add a custom vendor
    func addVendor(_ vendor: VendorInfo) {
        vendors[vendor.teamId] = vendor

        // Persist to database
        try? DatabaseManager.shared.addKnownVendor(
            teamId: vendor.teamId,
            name: vendor.name,
            category: vendor.category?.rawValue
        )
    }

    // MARK: - Private Methods

    private func loadBuiltInVendors() {
        // Load from bundled JSON file
        if let url = Bundle.main.url(forResource: "KnownVendors", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let vendorList = try? JSONDecoder().decode([VendorInfo].self, from: data) {
            for vendor in vendorList {
                vendors[vendor.teamId] = vendor
            }
        } else {
            // Fallback to hardcoded list
            loadHardcodedVendors()
        }
    }

    private func loadUserVendors() {
        // Load additional vendors from database
        // This allows users to add their own trusted vendors
    }

    private func loadHardcodedVendors() {
        let builtInVendors: [VendorInfo] = [
            // Apple
            VendorInfo(teamId: "APPLECOMPUTER", name: "Apple", category: .system),

            // Major software vendors
            VendorInfo(teamId: "UBF8T346G9", name: "Microsoft Corporation", category: .productivity),
            VendorInfo(teamId: "JQ525L2MZD", name: "Adobe Inc.", category: .creativity),
            VendorInfo(teamId: "EQHXZ8M8AV", name: "Google LLC", category: .productivity),
            VendorInfo(teamId: "9NTXGM424S", name: "Slack Technologies, LLC", category: .productivity),
            VendorInfo(teamId: "BJ4HAAB9B3", name: "Zoom Video Communications, Inc.", category: .productivity),
            VendorInfo(teamId: "N9SQDT3S7S", name: "Spotify AB", category: .entertainment),

            // Development tools
            VendorInfo(teamId: "VEKTX9H2N7", name: "JetBrains s.r.o.", category: .development),
            VendorInfo(teamId: "Z72J2T6N8K", name: "GitHub, Inc.", category: .development),
            VendorInfo(teamId: "9B5WATR6TV", name: "Sublime HQ Pty Ltd", category: .development),
            VendorInfo(teamId: "MAES384C78", name: "Visual Studio Code (Microsoft)", category: .development),

            // Security software
            VendorInfo(teamId: "VBG97UB4TA", name: "1Password", category: .security),
            VendorInfo(teamId: "LMY4V34FPV", name: "Objective Development Software GmbH", category: .security), // Little Snitch
            VendorInfo(teamId: "ML43LWLQ3H", name: "Objective-See, LLC", category: .security),
            VendorInfo(teamId: "AAPZK3CB24", name: "Malwarebytes Corporation", category: .security),
            VendorInfo(teamId: "2BUA8C4S2C", name: "Panic Inc.", category: .development), // Transmit, Nova
            VendorInfo(teamId: "33YRLYRBYV", name: "Proxyman LLC", category: .development),

            // Virtualization
            VendorInfo(teamId: "EG7KH642X6", name: "VMware, Inc.", category: .virtualization),
            VendorInfo(teamId: "4CB3V7YF7S", name: "Parallels International GmbH", category: .virtualization),
            VendorInfo(teamId: "MXGJJ98X76", name: "Docker Inc.", category: .development),

            // Utilities
            VendorInfo(teamId: "WDNLXAD4W8", name: "Setapp Limited", category: .utilities),
            VendorInfo(teamId: "6N38VWS5BX", name: "Alfred App Ltd", category: .utilities),
            VendorInfo(teamId: "J8RPQ294UB", name: "MacPaw Inc.", category: .utilities), // CleanMyMac
            VendorInfo(teamId: "H43XF2J3Q6", name: "Raycast Technologies Inc.", category: .utilities),
            VendorInfo(teamId: "YJGMQURXY7", name: "Bartender (Surtees Studios)", category: .utilities),

            // Cloud storage
            VendorInfo(teamId: "G7HH3F8CAK", name: "Dropbox, Inc.", category: .cloudStorage),
            VendorInfo(teamId: "W5364U7YZB", name: "Box, Inc.", category: .cloudStorage),

            // Communication
            VendorInfo(teamId: "U68MSDN6DR", name: "Discord Inc.", category: .communication),
            VendorInfo(teamId: "AU8N7Y8MZ7", name: "Telegram FZ-LLC", category: .communication),
            VendorInfo(teamId: "T2BZH8JXDM", name: "WhatsApp Inc.", category: .communication),

            // Networking
            VendorInfo(teamId: "CU3UV4LZ2W", name: "Cloudflare, Inc.", category: .networking),
            VendorInfo(teamId: "68N9HDSKD4", name: "Private Internet Access", category: .networking),
            VendorInfo(teamId: "2J7NMR4R42", name: "NordVPN S.A.", category: .networking),

            // Hardware vendors
            VendorInfo(teamId: "72Z5XPEPR9", name: "Logitech Inc.", category: .hardware),
            VendorInfo(teamId: "SY64MV22Y9", name: "Sonos, Inc.", category: .hardware),
            VendorInfo(teamId: "74J4L3C7KL", name: "Elgato Systems GmbH", category: .hardware),

            // Other trusted software
            VendorInfo(teamId: "HL3DJ7YS5P", name: "Homebrew", category: .development),
            VendorInfo(teamId: "QWY4LRW926", name: "Oracle America, Inc.", category: .development), // Java
        ]

        for vendor in builtInVendors {
            vendors[vendor.teamId] = vendor
        }
    }
}

// MARK: - Supporting Types

struct VendorInfo: Codable, Identifiable {
    var id: String { teamId }

    let teamId: String
    let name: String
    let category: VendorCategory?
    let website: String?
    let verified: Bool

    init(
        teamId: String,
        name: String,
        category: VendorCategory? = nil,
        website: String? = nil,
        verified: Bool = true
    ) {
        self.teamId = teamId
        self.name = name
        self.category = category
        self.website = website
        self.verified = verified
    }
}

enum VendorCategory: String, Codable, CaseIterable {
    case system = "system"
    case security = "security"
    case productivity = "productivity"
    case development = "development"
    case creativity = "creativity"
    case entertainment = "entertainment"
    case communication = "communication"
    case virtualization = "virtualization"
    case utilities = "utilities"
    case cloudStorage = "cloud_storage"
    case networking = "networking"
    case hardware = "hardware"
    case other = "other"

    var displayName: String {
        switch self {
        case .system: return "System"
        case .security: return "Security"
        case .productivity: return "Productivity"
        case .development: return "Development"
        case .creativity: return "Creativity"
        case .entertainment: return "Entertainment"
        case .communication: return "Communication"
        case .virtualization: return "Virtualization"
        case .utilities: return "Utilities"
        case .cloudStorage: return "Cloud Storage"
        case .networking: return "Networking"
        case .hardware: return "Hardware"
        case .other: return "Other"
        }
    }
}
