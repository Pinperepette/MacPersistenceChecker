import Foundation
import AppKit

// MARK: - Models

/// Info about junk files in Library
struct LibraryLocation: Hashable {
    let path: String
    let type: String  // "App Support", "Caches", etc.
    let size: Int64
    let weight: Int
}

/// Aggregated junk info for an app
struct AppJunkInfo: Hashable {
    var locations: [LibraryLocation] = []
    var totalSize: Int64 = 0
    var totalWeight: Int = 0

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

/// Extended score details for UI display
struct AppScoreDetails {
    var persistenceScore: Int = 0
    var junkScore: Int = 0
    var totalScore: Int = 0
    var persistenceDetails: [InvasivenessScorer.ScoreDetail] = []
    var junkDetails: [InvasivenessScorer.ScoreDetail] = []
}

/// Represents an analyzed application with its invasiveness metrics
struct AnalyzedApp: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let bundleIdentifier: String?
    let path: URL
    let icon: NSImage?

    // Persistence items found
    var launchAgents: [PersistenceItem] = []
    var launchDaemons: [PersistenceItem] = []
    var loginItems: [PersistenceItem] = []
    var privilegedHelpers: [PersistenceItem] = []
    var kernelExtensions: [PersistenceItem] = []
    var systemExtensions: [PersistenceItem] = []
    var browserExtensions: [PersistenceItem] = []
    var otherItems: [PersistenceItem] = []

    // Junk info from Library scan
    var junkInfo: AppJunkInfo?

    // Detailed score breakdown
    var scoreDetails: AppScoreDetails?

    // Calculated metrics
    var totalPersistenceItems: Int {
        launchAgents.count + launchDaemons.count + loginItems.count +
        privilegedHelpers.count + kernelExtensions.count + systemExtensions.count +
        browserExtensions.count + otherItems.count
    }

    var totalJunkLocations: Int {
        junkInfo?.locations.count ?? 0
    }

    var invasivenessScore: Int = 0
    var grade: InvasivenessGrade = .unknown

    // All items for this app
    var allItems: [PersistenceItem] {
        launchAgents + launchDaemons + loginItems + privilegedHelpers +
        kernelExtensions + systemExtensions + browserExtensions + otherItems
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AnalyzedApp, rhs: AnalyzedApp) -> Bool {
        lhs.id == rhs.id
    }
}

/// Grade for app invasiveness
enum InvasivenessGrade: String, CaseIterable {
    case clean = "A"      // 0-15
    case good = "B"       // 16-30
    case moderate = "C"   // 31-50
    case invasive = "D"   // 51-70
    case veryInvasive = "F" // 71+
    case unknown = "?"

    var displayName: String {
        switch self {
        case .clean: return "Clean"
        case .good: return "Good"
        case .moderate: return "Moderate"
        case .invasive: return "Invasive"
        case .veryInvasive: return "Very Invasive"
        case .unknown: return "Unknown"
        }
    }

    var emoji: String {
        switch self {
        case .clean: return "🟢"
        case .good: return "🟢"
        case .moderate: return "🟡"
        case .invasive: return "🟠"
        case .veryInvasive: return "🔴"
        case .unknown: return "⚪"
        }
    }

    var color: String {
        switch self {
        case .clean, .good: return "green"
        case .moderate: return "yellow"
        case .invasive: return "orange"
        case .veryInvasive: return "red"
        case .unknown: return "gray"
        }
    }

    static func from(score: Int) -> InvasivenessGrade {
        switch score {
        case 0...15: return .clean
        case 16...30: return .good
        case 31...50: return .moderate
        case 51...70: return .invasive
        default: return .veryInvasive
        }
    }
}

// MARK: - Analyzer

/// Analyzes installed applications for their invasiveness
@MainActor
final class AppInvasivenessAnalyzer: ObservableObject {
    static let shared = AppInvasivenessAnalyzer()

    @Published var analyzedApps: [AnalyzedApp] = []
    @Published var isAnalyzing: Bool = false
    @Published var progress: Double = 0
    @Published var currentApp: String = ""

    // Known bundle ID patterns for matching
    private let knownVendorPatterns: [String: [String]] = [
        "Adobe": ["com.adobe", "com.Adobe"],
        "Microsoft": ["com.microsoft", "com.Microsoft"],
        "Google": ["com.google", "com.Google"],
        "Apple": ["com.apple"],
        "Spotify": ["com.spotify"],
        "Slack": ["com.tinyspeck.slackmacgap", "com.slack"],
        "Discord": ["com.hnc.Discord", "com.discord"],
        "Zoom": ["us.zoom"],
        "Dropbox": ["com.dropbox", "com.getdropbox"],
        "1Password": ["com.1password", "com.agilebits"],
        "JetBrains": ["com.jetbrains"],
        "Docker": ["com.docker"],
        "Parallels": ["com.parallels"],
        "VMware": ["com.vmware"],
        "Malwarebytes": ["com.malwarebytes"],
        "CleanMyMac": ["com.macpaw"],
        "Little Snitch": ["at.obdev"],
        "Bartender": ["com.surteesstudios"],
        "Alfred": ["com.runningwithcrayons"],
        "Homebrew": ["com.homebrew", "homebrew"],
    ]

    private init() {}

    /// Analyze ALL junk/files installed by apps in ~/Library and system locations
    func analyzeAllApps(persistenceItems: [PersistenceItem]) async {
        isAnalyzing = true
        progress = 0
        analyzedApps = []
        currentApp = "Scanning Library folders..."

        let home = NSHomeDirectory()

        // Directories to scan for app junk
        let libraryDirs: [(path: String, weight: Int, name: String)] = [
            ("\(home)/Library/Application Support", 3, "App Support"),
            ("\(home)/Library/Caches", 1, "Caches"),
            ("\(home)/Library/Preferences", 2, "Preferences"),
            ("\(home)/Library/Containers", 2, "Containers"),
            ("\(home)/Library/Group Containers", 2, "Group Containers"),
            ("\(home)/Library/Saved Application State", 1, "Saved State"),
            ("\(home)/Library/Logs", 1, "Logs"),
            ("/Library/Application Support", 4, "System App Support"),
            ("/Library/Caches", 1, "System Caches"),
            ("/Library/Preferences", 3, "System Preferences"),
        ]

        // Track junk per app/vendor
        var appJunk: [String: AppJunkInfo] = [:]

        let totalDirs = libraryDirs.count

        for (index, (dirPath, weight, dirName)) in libraryDirs.enumerated() {
            currentApp = "Scanning \(dirName)..."
            progress = Double(index) / Double(totalDirs) * 0.5
            await Task.yield() // Allow UI to update

            // Scan directory in background
            let dirResults = await scanDirectory(path: dirPath, weight: weight, dirName: dirName)

            // Merge results
            for (appName, locations) in dirResults {
                if appJunk[appName] == nil {
                    appJunk[appName] = AppJunkInfo()
                }
                for location in locations {
                    appJunk[appName]!.locations.append(location)
                    appJunk[appName]!.totalSize += location.size
                    appJunk[appName]!.totalWeight += location.weight
                }
            }
        }

        currentApp = "Matching persistence items..."
        progress = 0.6
        await Task.yield()

        // Match persistence items to apps
        var appPersistence: [String: [PersistenceItem]] = [:]
        for item in persistenceItems {
            // Skip Apple items
            if item.trustLevel == .apple { continue }

            let appName = extractAppNameFromPersistence(item)
            if appPersistence[appName] == nil {
                appPersistence[appName] = []
            }
            appPersistence[appName]!.append(item)
        }

        currentApp = "Calculating scores..."
        progress = 0.75

        // Merge all app names
        var allAppNames = Set(appJunk.keys)
        allAppNames.formUnion(appPersistence.keys)

        // Convert to AnalyzedApp with comprehensive scoring
        var results: [AnalyzedApp] = []
        let appList = Array(allAppNames)

        for (index, appName) in appList.enumerated() {
            if index % 20 == 0 {
                progress = 0.75 + (Double(index) / Double(appList.count) * 0.2)
                currentApp = "Processing \(appName)..."
            }

            let junkInfo = appJunk[appName]
            let items = appPersistence[appName] ?? []

            // Check if there's a matching app in /Applications
            let hasMatchingApp = checkAppExists(appName)

            // Use InvasivenessScorer for comprehensive scoring
            let scoreResult = InvasivenessScorer.calculateTotalScore(
                appName: appName,
                persistenceItems: items,
                junkInfo: junkInfo,
                hasMatchingApp: hasMatchingApp
            )

            var app = AnalyzedApp(
                name: appName,
                bundleIdentifier: nil,
                path: URL(fileURLWithPath: "/Applications/\(appName).app"),
                icon: nil
            )

            // Categorize persistence items
            for item in items {
                switch item.category {
                case .launchAgents:
                    app.launchAgents.append(item)
                case .launchDaemons:
                    app.launchDaemons.append(item)
                case .loginItems:
                    app.loginItems.append(item)
                case .privilegedHelpers:
                    app.privilegedHelpers.append(item)
                case .kernelExtensions:
                    app.kernelExtensions.append(item)
                case .systemExtensions:
                    app.systemExtensions.append(item)
                default:
                    app.otherItems.append(item)
                }
            }

            // Store scores
            app.invasivenessScore = scoreResult.totalScore
            app.grade = scoreResult.grade
            app.junkInfo = junkInfo

            // Store detailed score breakdown
            app.scoreDetails = AppScoreDetails(
                persistenceScore: scoreResult.persistenceScore,
                junkScore: scoreResult.junkScore,
                totalScore: scoreResult.totalScore,
                persistenceDetails: scoreResult.persistenceDetails,
                junkDetails: scoreResult.junkDetails
            )

            results.append(app)
        }

        progress = 1.0

        // Sort by total score (most invasive first)
        analyzedApps = results.sorted { $0.invasivenessScore > $1.invasivenessScore }
        isAnalyzing = false
        currentApp = ""
    }

    /// Scan a single directory for junk (runs in background) - FAST: no size calculation
    private func scanDirectory(path: String, weight: Int, dirName: String) async -> [String: [LibraryLocation]] {
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var results: [String: [LibraryLocation]] = [:]

            guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
                return results
            }

            for item in contents {
                // Skip Apple/system items
                let itemLower = item.lowercased()
                if itemLower.hasPrefix("com.apple.") || itemLower.hasPrefix("apple") ||
                   itemLower == ".ds_store" || itemLower.hasPrefix(".") {
                    continue
                }

                let fullPath = "\(path)/\(item)"
                let appName = self.extractAppName(from: item)

                // Skip size calculation for speed - size=0 initially, calculated on demand
                let location = LibraryLocation(
                    path: fullPath,
                    type: dirName,
                    size: 0,  // Will be calculated on demand
                    weight: weight
                )

                if results[appName] == nil {
                    results[appName] = []
                }
                results[appName]!.append(location)
            }

            return results
        }.value
    }

    /// Calculate folder size on demand (called when viewing app details)
    func calculateSizeForApp(_ app: AnalyzedApp) async -> AppJunkInfo? {
        guard let junkInfo = app.junkInfo else { return nil }

        var updatedInfo = junkInfo
        updatedInfo.totalSize = 0

        var updatedLocations: [LibraryLocation] = []

        for location in junkInfo.locations {
            let size = await Task.detached(priority: .utility) {
                self.getFolderSize(path: location.path)
            }.value

            let updated = LibraryLocation(
                path: location.path,
                type: location.type,
                size: size,
                weight: location.weight
            )
            updatedLocations.append(updated)
            updatedInfo.totalSize += size
        }

        updatedInfo.locations = updatedLocations
        return updatedInfo
    }

    /// Extract app name from persistence item
    private nonisolated func extractAppNameFromPersistence(_ item: PersistenceItem) -> String {
        let identifier = item.identifier.lowercased()

        // Try to extract from bundle identifier like "com.vendor.appname"
        let parts = identifier.components(separatedBy: ".")

        if parts.count >= 3 {
            // Skip common prefixes and get the meaningful part
            let skipPrefixes = ["com", "org", "net", "io", "app", "me", "co", "us", "de", "uk", "fr", "at"]
            for part in parts {
                if skipPrefixes.contains(part) || part.count <= 2 {
                    continue
                }
                // Capitalize first letter
                return part.prefix(1).uppercased() + part.dropFirst()
            }
        }

        // Fallback: use item name
        let name = item.name
        if let firstWord = name.components(separatedBy: CharacterSet.alphanumerics.inverted).first(where: { $0.count > 2 }) {
            return firstWord.prefix(1).uppercased() + firstWord.dropFirst().lowercased()
        }

        return item.name
    }

    /// Check if an app exists in /Applications
    private nonisolated func checkAppExists(_ appName: String) -> Bool {
        let fm = FileManager.default
        let appDirs = ["/Applications", NSHomeDirectory() + "/Applications"]

        let variations = [
            appName,
            appName.replacingOccurrences(of: " ", with: ""),
            appName.lowercased(),
            appName.lowercased().replacingOccurrences(of: " ", with: "")
        ]

        for dir in appDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let itemName = item.replacingOccurrences(of: ".app", with: "").lowercased()
                for variation in variations {
                    if itemName.contains(variation.lowercased()) || variation.lowercased().contains(itemName) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Extract app name from folder/file name
    private nonisolated func extractAppName(from name: String) -> String {
        var cleanName = name

        // Remove common prefixes
        let prefixes = ["com.", "org.", "net.", "io.", "co.", "me."]
        for prefix in prefixes {
            if cleanName.lowercased().hasPrefix(prefix) {
                cleanName = String(cleanName.dropFirst(prefix.count))
                break
            }
        }

        // Split by dots and get meaningful part
        let parts = cleanName.components(separatedBy: ".")
        if parts.count > 1 {
            // Take first non-generic part
            for part in parts {
                let lower = part.lowercased()
                if !["com", "org", "app", "mac", "macos", "helper", "agent", "plist"].contains(lower) && part.count > 2 {
                    cleanName = part
                    break
                }
            }
        }

        // Capitalize first letter
        if let first = cleanName.first {
            cleanName = first.uppercased() + cleanName.dropFirst()
        }

        return cleanName
    }

    /// Get folder size in bytes
    private nonisolated func getFolderSize(path: String) -> Int64 {
        let fm = FileManager.default
        var totalSize: Int64 = 0

        guard let enumerator = fm.enumerator(atPath: path) else {
            // Single file
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64 {
                return size
            }
            return 0
        }

        while let file = enumerator.nextObject() as? String {
            let fullPath = "\(path)/\(file)"
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 {
                totalSize += size
            }
        }

        return totalSize
    }

    /// Extract vendor name from persistence item identifier
    private nonisolated func extractVendor(from item: PersistenceItem) -> String {
        let identifier = item.identifier.lowercased()

        // Try to extract vendor from identifier like "com.vendor.something"
        let parts = identifier.components(separatedBy: ".")

        if parts.count >= 2 {
            // Skip "com", "org", "net", "io" etc
            let skipPrefixes = ["com", "org", "net", "io", "app", "me", "co", "us", "de", "uk", "fr", "at"]
            var vendorPart = ""

            for part in parts {
                if skipPrefixes.contains(part) || part.count <= 2 {
                    continue
                }
                vendorPart = part
                break
            }

            if !vendorPart.isEmpty {
                // Capitalize first letter
                return vendorPart.prefix(1).uppercased() + vendorPart.dropFirst()
            }
        }

        // Fallback: use item name or first meaningful part
        let name = item.name
        if let firstWord = name.components(separatedBy: CharacterSet.alphanumerics.inverted).first(where: { $0.count > 2 }) {
            return firstWord.prefix(1).uppercased() + firstWord.dropFirst().lowercased()
        }

        return "Unknown"
    }

    /// Try to find an app that matches this vendor
    private nonisolated func findAppForVendor(_ vendor: String, items: [PersistenceItem]) -> (name: String, bundleID: String?, path: URL?) {
        let vendorLower = vendor.lowercased()
        let fm = FileManager.default

        // Common vendor name mappings
        let vendorMappings: [String: String] = [
            "microsoft": "Microsoft",
            "adobe": "Adobe",
            "google": "Google",
            "apple": "Apple",
            "dropbox": "Dropbox",
            "spotify": "Spotify",
            "slack": "Slack",
            "zoom": "Zoom",
            "docker": "Docker",
            "jetbrains": "JetBrains",
            "vmware": "VMware",
            "parallels": "Parallels",
            "1password": "1Password",
            "agilebits": "1Password",
            "macpaw": "MacPaw (CleanMyMac)",
            "obdev": "Objective Development (Little Snitch)",
            "objective-see": "Objective-See",
            "malwarebytes": "Malwarebytes",
            "teamviewer": "TeamViewer",
            "virtualbox": "VirtualBox",
            "oracle": "Oracle (VirtualBox)",
            "homebrew": "Homebrew",
            "cindori": "Cindori (Sensei)",
        ]

        // Check if we have a known mapping
        if let mapped = vendorMappings[vendorLower] {
            return (mapped, nil, nil)
        }

        // Try to find app in /Applications
        let appDirs = ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]

        for dir in appDirs {
            if let contents = try? fm.contentsOfDirectory(atPath: dir) {
                for item in contents where item.hasSuffix(".app") {
                    let appName = item.replacingOccurrences(of: ".app", with: "").lowercased()
                    if appName.contains(vendorLower) || vendorLower.contains(appName.replacingOccurrences(of: " ", with: "")) {
                        let path = URL(fileURLWithPath: dir).appendingPathComponent(item)
                        let bundleID = Bundle(url: path)?.bundleIdentifier
                        return (item.replacingOccurrences(of: ".app", with: ""), bundleID, path)
                    }
                }
            }
        }

        // Return vendor name as-is
        return (vendor, nil, nil)
    }

    /// Synchronous app analysis for background thread
    private nonisolated func analyzeAppSync(at appURL: URL, allItems: [PersistenceItem]) -> AnalyzedApp {
        let appName = appURL.deletingPathExtension().lastPathComponent
        let bundleID = Bundle(url: appURL)?.bundleIdentifier

        var app = AnalyzedApp(
            name: appName,
            bundleIdentifier: bundleID,
            path: appURL,
            icon: nil  // Skip icon loading in background
        )

        // Find all persistence items that belong to this app
        let matchingItems = findMatchingItemsSync(for: app, in: allItems)

        // Categorize items
        for item in matchingItems {
            switch item.category {
            case .launchAgents:
                app.launchAgents.append(item)
            case .launchDaemons:
                app.launchDaemons.append(item)
            case .loginItems:
                app.loginItems.append(item)
            case .privilegedHelpers:
                app.privilegedHelpers.append(item)
            case .kernelExtensions:
                app.kernelExtensions.append(item)
            case .systemExtensions:
                app.systemExtensions.append(item)
            default:
                app.otherItems.append(item)
            }
        }

        return app
    }

    /// Synchronous item matching for background thread
    private nonisolated func findMatchingItemsSync(for app: AnalyzedApp, in items: [PersistenceItem]) -> [PersistenceItem] {
        var matches: [PersistenceItem] = []

        let appNameLower = app.name.lowercased()
        // Create multiple variations of app name for matching
        let appNameVariations = createNameVariations(appNameLower)
        let bundleIDLower = app.bundleIdentifier?.lowercased()

        // Only consider real persistence categories
        let validCategories: Set<PersistenceCategory> = [
            .launchAgents, .launchDaemons, .loginItems, .privilegedHelpers,
            .kernelExtensions, .systemExtensions, .cronJobs, .authorizationPlugins
        ]

        for item in items {
            // Skip items that aren't real persistence mechanisms
            guard validCategories.contains(item.category) else { continue }

            // Skip Apple items - they're not from third-party apps
            if item.trustLevel == .apple { continue }

            let itemIdentifierLower = item.identifier.lowercased()
            let itemNameLower = item.name.lowercased()
            let execPathLower = item.executablePath?.path.lowercased() ?? ""

            var isMatch = false

            // 1. Match by bundle identifier prefix (com.vendor)
            if let bundleID = bundleIDLower {
                let bundleComponents = bundleID.components(separatedBy: ".")

                // Try different prefix lengths
                if bundleComponents.count >= 2 {
                    let prefix2 = bundleComponents.prefix(2).joined(separator: ".")
                    if itemIdentifierLower.hasPrefix(prefix2) {
                        isMatch = true
                    }
                }

                if bundleComponents.count >= 3 && !isMatch {
                    let prefix3 = bundleComponents.prefix(3).joined(separator: ".")
                    if itemIdentifierLower.hasPrefix(prefix3) {
                        isMatch = true
                    }
                }

                // Check if significant parts of bundle ID appear in item identifier
                for part in bundleComponents {
                    // Skip common/short parts
                    if part.count <= 3 || ["com", "app", "mac", "osx", "macos", "helper", "agent", "daemon"].contains(part) {
                        continue
                    }
                    if itemIdentifierLower.contains(part) {
                        isMatch = true
                        break
                    }
                }
            }

            // 2. Match by app name variations in identifier or item name
            for variation in appNameVariations {
                if variation.count >= 4 {  // Only match if variation is meaningful
                    if itemIdentifierLower.contains(variation) || itemNameLower.contains(variation) {
                        isMatch = true
                        break
                    }
                }
            }

            // 3. Match by executable path containing app name or bundle
            if !execPathLower.isEmpty {
                // Direct app bundle match
                if execPathLower.contains(app.path.path.lowercased()) {
                    isMatch = true
                }

                // App name in path
                for variation in appNameVariations where variation.count >= 4 {
                    if execPathLower.contains(variation) {
                        isMatch = true
                        break
                    }
                }
            }

            if isMatch {
                matches.append(item)
            }
        }

        return matches
    }

    /// Create variations of app name for matching
    private nonisolated func createNameVariations(_ appName: String) -> [String] {
        var variations: [String] = [appName]

        // Remove spaces
        let noSpaces = appName.replacingOccurrences(of: " ", with: "")
        variations.append(noSpaces)

        // Remove common suffixes
        let suffixesToRemove = [" app", " for mac", " mac", " pro", " lite", " free"]
        for suffix in suffixesToRemove {
            if appName.hasSuffix(suffix) {
                variations.append(String(appName.dropLast(suffix.count)))
            }
        }

        // Split camelCase or spaces and use parts
        let words = appName.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        variations.append(contentsOf: words)

        // Remove duplicates and empty strings
        return Array(Set(variations.filter { !$0.isEmpty }))
    }

    /// Get all installed applications
    private func getInstalledApps() async -> [URL] {
        var apps: [URL] = []
        let fm = FileManager.default

        let appDirectories = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")
        ]

        for dir in appDirectories {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }

            for item in contents {
                if item.pathExtension == "app" {
                    apps.append(item)
                }
            }
        }

        return apps
    }

    /// Analyze a single application
    private func analyzeApp(at appURL: URL, allItems: [PersistenceItem]) async -> AnalyzedApp {
        let appName = appURL.deletingPathExtension().lastPathComponent
        let bundleID = Bundle(url: appURL)?.bundleIdentifier
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)

        var app = AnalyzedApp(
            name: appName,
            bundleIdentifier: bundleID,
            path: appURL,
            icon: icon
        )

        // Find all persistence items that belong to this app
        let matchingItems = findMatchingItems(for: app, in: allItems)

        // Categorize items
        for item in matchingItems {
            switch item.category {
            case .launchAgents:
                app.launchAgents.append(item)
            case .launchDaemons:
                app.launchDaemons.append(item)
            case .loginItems:
                app.loginItems.append(item)
            case .privilegedHelpers:
                app.privilegedHelpers.append(item)
            case .kernelExtensions:
                app.kernelExtensions.append(item)
            case .systemExtensions:
                app.systemExtensions.append(item)
            default:
                app.otherItems.append(item)
            }
        }

        return app
    }

    /// Find persistence items that belong to an app
    private func findMatchingItems(for app: AnalyzedApp, in items: [PersistenceItem]) -> [PersistenceItem] {
        var matches: [PersistenceItem] = []

        let appNameLower = app.name.lowercased()
        let bundleIDLower = app.bundleIdentifier?.lowercased()

        // Get vendor pattern if known
        let vendorPatterns = getVendorPatterns(for: app)

        for item in items {
            let itemNameLower = item.name.lowercased()
            let itemIdentifierLower = item.identifier.lowercased()
            let itemPathLower = item.plistPath?.path.lowercased() ?? ""
            let execPathLower = item.executablePath?.path.lowercased() ?? ""

            var isMatch = false

            // Match by bundle identifier
            if let bundleID = bundleIDLower {
                let bundlePrefix = bundleID.components(separatedBy: ".").prefix(3).joined(separator: ".")
                if itemIdentifierLower.hasPrefix(bundlePrefix) ||
                   itemIdentifierLower.contains(bundleID) {
                    isMatch = true
                }
            }

            // Match by app name
            let appNameNormalized = appNameLower.replacingOccurrences(of: " ", with: "")
            if itemNameLower.contains(appNameNormalized) ||
               itemIdentifierLower.contains(appNameNormalized) ||
               itemPathLower.contains(appNameNormalized) ||
               execPathLower.contains(appNameNormalized) {
                isMatch = true
            }

            // Match by vendor patterns
            for pattern in vendorPatterns {
                if itemIdentifierLower.hasPrefix(pattern.lowercased()) ||
                   itemPathLower.contains(pattern.lowercased()) {
                    isMatch = true
                    break
                }
            }

            // Match by executable path containing the app
            if execPathLower.contains(app.path.path.lowercased()) {
                isMatch = true
            }

            if isMatch {
                matches.append(item)
            }
        }

        return matches
    }

    /// Get vendor patterns for matching
    private func getVendorPatterns(for app: AnalyzedApp) -> [String] {
        var patterns: [String] = []

        if let bundleID = app.bundleIdentifier {
            // Add bundle ID prefix as pattern
            let components = bundleID.components(separatedBy: ".")
            if components.count >= 2 {
                patterns.append(components.prefix(2).joined(separator: "."))
            }
        }

        // Check known vendor patterns
        for (_, vendorPatterns) in knownVendorPatterns {
            for pattern in vendorPatterns {
                if app.bundleIdentifier?.lowercased().hasPrefix(pattern.lowercased()) == true {
                    patterns.append(contentsOf: vendorPatterns)
                    break
                }
            }
        }

        return patterns
    }

    /// Calculate invasiveness score for an app
    private nonisolated func calculateInvasivenessScore(for app: AnalyzedApp) -> Int {
        var score = 0

        // LaunchAgents: 8 points each
        score += app.launchAgents.count * 8

        // LaunchDaemons: 15 points each (system-level)
        score += app.launchDaemons.count * 15

        // Login Items: 5 points each
        score += app.loginItems.count * 5

        // Privileged Helpers: 20 points each (elevated privileges)
        score += app.privilegedHelpers.count * 20

        // Kernel Extensions: 25 points each (kernel-level access)
        score += app.kernelExtensions.count * 25

        // System Extensions: 15 points each
        score += app.systemExtensions.count * 15

        // Other items: 5 points each
        score += app.otherItems.count * 5

        // Bonus penalties
        for item in app.allItems {
            // Unsigned items: +10
            if item.signatureInfo == nil || item.trustLevel == .unsigned {
                score += 10
            }

            // Suspicious items: +15
            if item.trustLevel == .suspicious {
                score += 15
            }

            // High risk score: +5
            if let riskScore = item.riskScore, riskScore > 50 {
                score += 5
            }

            // RunAtLoad: +3
            if item.runAtLoad == true {
                score += 3
            }

            // KeepAlive: +5 (constantly running)
            if item.keepAlive == true {
                score += 5
            }
        }

        return min(100, score)
    }

    // MARK: - Statistics

    var totalAppsAnalyzed: Int {
        analyzedApps.count
    }

    var cleanApps: Int {
        analyzedApps.filter { $0.grade == .clean || $0.grade == .good }.count
    }

    var invasiveApps: Int {
        analyzedApps.filter { $0.grade == .invasive || $0.grade == .veryInvasive }.count
    }

    var averageScore: Int {
        guard !analyzedApps.isEmpty else { return 0 }
        let total = analyzedApps.reduce(0) { $0 + $1.invasivenessScore }
        return total / analyzedApps.count
    }

    var mostInvasive: AnalyzedApp? {
        analyzedApps.first
    }

    func appsWithGrade(_ grade: InvasivenessGrade) -> [AnalyzedApp] {
        analyzedApps.filter { $0.grade == grade }
    }
}

// MARK: - Report Generation

extension AppInvasivenessAnalyzer {
    /// Generate a text report of the analysis
    func generateReport() -> String {
        var report = """
        ╔════════════════════════════════════════════════════════════════╗
        ║          APP INVASIVENESS REPORT - MacPersistenceChecker       ║
        ╚════════════════════════════════════════════════════════════════╝

        Generated: \(Date().formatted())
        Apps Analyzed: \(totalAppsAnalyzed)
        Average Score: \(averageScore)/100

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                   SUMMARY
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        🟢 Clean/Good (A-B): \(cleanApps) apps
        🟡 Moderate (C): \(appsWithGrade(.moderate).count) apps
        🟠 Invasive (D): \(appsWithGrade(.invasive).count) apps
        🔴 Very Invasive (F): \(appsWithGrade(.veryInvasive).count) apps

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                  RANKING
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        """

        for (index, app) in analyzedApps.enumerated() {
            report += """

            \(index + 1). \(app.grade.emoji) \(app.name) (\(app.invasivenessScore)/100) - \(app.grade.displayName.uppercased())
               Bundle ID: \(app.bundleIdentifier ?? "Unknown")

            """

            if !app.launchAgents.isEmpty {
                report += "   • LaunchAgents: \(app.launchAgents.count)\n"
                for item in app.launchAgents.prefix(3) {
                    report += "     - \(item.name)\n"
                }
                if app.launchAgents.count > 3 {
                    report += "     ... and \(app.launchAgents.count - 3) more\n"
                }
            }

            if !app.launchDaemons.isEmpty {
                report += "   • LaunchDaemons: \(app.launchDaemons.count)\n"
                for item in app.launchDaemons.prefix(3) {
                    report += "     - \(item.name)\n"
                }
            }

            if !app.privilegedHelpers.isEmpty {
                report += "   • Privileged Helpers: \(app.privilegedHelpers.count)\n"
            }

            if !app.kernelExtensions.isEmpty {
                report += "   • Kernel Extensions: \(app.kernelExtensions.count)\n"
            }

            if !app.loginItems.isEmpty {
                report += "   • Login Items: \(app.loginItems.count)\n"
            }

            report += "\n"
        }

        report += """

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        Note: Higher scores indicate more system-level persistence mechanisms.
        This doesn't necessarily mean the app is malicious, but it does mean
        the app has deeper integration with your system.

        """

        return report
    }
}
