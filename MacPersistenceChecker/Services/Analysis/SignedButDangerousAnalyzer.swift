import Foundation

/// Detects "Signed-but-Dangerous" items - properly signed/notarized but suspicious
/// This catches modern macOS malware that bypasses traditional unsigned detection
final class SignedButDangerousAnalyzer {

    static let shared = SignedButDangerousAnalyzer()

    // MARK: - Known Good Team IDs (loaded from KnownVendors.json)

    /// Team IDs of well-known, trusted software vendors
    private lazy var trustedTeamIDs: Set<String> = loadTrustedTeamIDs()

    private func loadTrustedTeamIDs() -> Set<String> {
        var teamIDs = Set<String>()

        // Try to load from bundle resource (works for both app bundle and Swift Package)
        if let url = Bundle.module.url(forResource: "KnownVendors", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let vendors = try? JSONDecoder().decode([KnownVendor].self, from: data) {
            for vendor in vendors {
                teamIDs.insert(vendor.teamId)
            }
        }

        // Add some well-known ones as fallback
        let fallbackIDs = [
            "EQHXZ8M8AV",  // Google
            "UBF8T346G9",  // Microsoft
            "JQ525L2MZD",  // Adobe
            "MXGJJ98X76",  // Docker
            "G7HH3F8CAK",  // Dropbox
        ]
        teamIDs.formUnion(fallbackIDs)

        return teamIDs
    }

    struct KnownVendor: Codable {
        let teamId: String
        let name: String
        let category: String
        let verified: Bool
    }

    // MARK: - Dangerous Entitlements

    /// Entitlements that are suspicious for most apps
    private let dangerousEntitlements: [String: DangerousEntitlement] = [
        "com.apple.security.cs.allow-unsigned-executable-memory": DangerousEntitlement(
            name: "Unsigned Executable Memory",
            severity: .high,
            description: "Can execute unsigned code in memory - used for JIT but also shellcode"
        ),
        "com.apple.security.cs.disable-library-validation": DangerousEntitlement(
            name: "Disable Library Validation",
            severity: .critical,
            description: "Can load unsigned dylibs - common malware technique"
        ),
        "com.apple.security.cs.allow-dyld-environment-variables": DangerousEntitlement(
            name: "DYLD Environment Variables",
            severity: .critical,
            description: "Can use DYLD_INSERT_LIBRARIES - classic injection vector"
        ),
        "com.apple.security.cs.disable-executable-page-protection": DangerousEntitlement(
            name: "Disable Executable Page Protection",
            severity: .high,
            description: "Can modify executable pages - enables code injection"
        ),
        "com.apple.security.get-task-allow": DangerousEntitlement(
            name: "Get Task Allow",
            severity: .medium,
            description: "Allows debugging/injection by other processes"
        ),
        "com.apple.security.cs.debugger": DangerousEntitlement(
            name: "Debugger Entitlement",
            severity: .high,
            description: "Can debug other processes - powerful for attacks"
        ),
        "com.apple.private.tcc.allow": DangerousEntitlement(
            name: "TCC Bypass (Private)",
            severity: .critical,
            description: "Private entitlement to bypass TCC - should only be Apple"
        ),
        "com.apple.rootless.install": DangerousEntitlement(
            name: "SIP Bypass Install",
            severity: .critical,
            description: "Can write to SIP-protected locations"
        ),
        "com.apple.rootless.install.heritable": DangerousEntitlement(
            name: "SIP Bypass Heritable",
            severity: .critical,
            description: "Child processes inherit SIP bypass"
        ),
        "com.apple.security.temporary-exception.mach-lookup.global-name": DangerousEntitlement(
            name: "Mach Lookup Exception",
            severity: .medium,
            description: "Can communicate with arbitrary Mach services"
        ),
        "keychain-access-groups": DangerousEntitlement(
            name: "Keychain Access",
            severity: .low,
            description: "Can access keychain items"
        ),
        "com.apple.developer.endpoint-security.client": DangerousEntitlement(
            name: "Endpoint Security Client",
            severity: .high,
            description: "Can monitor all system events - powerful surveillance capability"
        ),
        "com.apple.developer.system-extension.install": DangerousEntitlement(
            name: "System Extension Install",
            severity: .high,
            description: "Can install kernel-level extensions"
        ),
    ]

    // MARK: - Analysis

    struct AnalysisResult {
        let flags: [DangerFlag]
        let overallRisk: RiskLevel
        let summary: String

        var additionalRiskPoints: Int {
            flags.reduce(0) { $0 + $1.points }
        }

        enum RiskLevel: String {
            case safe = "Safe"
            case lowRisk = "Low Risk"
            case suspicious = "Suspicious"
            case dangerous = "Dangerous"
            case critical = "Critical"

            var color: String {
                switch self {
                case .safe: return "green"
                case .lowRisk: return "blue"
                case .suspicious: return "yellow"
                case .dangerous: return "orange"
                case .critical: return "red"
                }
            }
        }
    }

    struct DangerFlag: Identifiable {
        let id = UUID()
        let type: FlagType
        let title: String
        let description: String
        let points: Int
        let severity: Severity

        enum FlagType: String {
            case recentCertificate = "recent_cert"
            case unknownTeamID = "unknown_team"
            case dangerousEntitlement = "dangerous_entitlement"
            case recentlyAdded = "recently_added"
            case noReputation = "no_reputation"
            case signedNotNotarized = "signed_not_notarized"
            case suspiciousName = "suspicious_name"
            case hiddenLocation = "hidden_location"
            case mismatchedInfo = "mismatched_info"
        }

        enum Severity: String {
            case info = "Info"
            case low = "Low"
            case medium = "Medium"
            case high = "High"
            case critical = "Critical"
        }
    }

    struct DangerousEntitlement {
        let name: String
        let severity: DangerFlag.Severity
        let description: String
    }

    // MARK: - Public API

    /// Analyze a persistence item for "signed but dangerous" indicators
    func analyze(item: PersistenceItem) -> AnalysisResult {
        var flags: [DangerFlag] = []

        guard let sig = item.signatureInfo, sig.isSigned else {
            // Not signed - handled by regular risk scoring
            return AnalysisResult(flags: [], overallRisk: .safe, summary: "Not applicable - unsigned")
        }

        // 1. Check certificate age - DISABLED (too many false positives)
        // New developers legitimately have new certificates
        // if let certDate = sig.certificateExpirationDate {
        //     let certAge = checkCertificateAge(expirationDate: certDate, sig: sig)
        //     if let flag = certAge {
        //         flags.append(flag)
        //     }
        // }

        // 2. Check Team ID reputation - ONLY flag truly suspicious cases
        // Most legitimate software won't have issues here
        if let teamID = sig.teamIdentifier, !teamID.isEmpty {
            // Has team ID - check if it's in trusted list (informational only, no flag)
            // We don't flag unknown team IDs anymore - too noisy
            _ = trustedTeamIDs.contains(teamID)
        }
        // Don't flag missing team ID - many legitimate apps don't have one
        // Apple binaries, ad-hoc signed developer builds, etc.

        // 3. Check entitlements (extract dynamically)
        if let execPath = item.effectiveExecutablePath {
            let entitlements = extractEntitlements(from: execPath)
            let entitlementFlags = checkEntitlements(item: item, entitlements: entitlements)
            flags.append(contentsOf: entitlementFlags)
        }

        // 4. Check if signed but NOT notarized (only suspicious if recently added)
        // Many legitimate older apps aren't notarized
        if sig.isSigned && sig.isValid && !sig.isNotarized && !sig.isAppleSigned {
            // Only flag if also recently added (new non-notarized app is more suspicious)
            let isRecent = item.plistModifiedAt.map {
                Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 999 < 30
            } ?? false

            if isRecent {
                flags.append(DangerFlag(
                    type: .signedNotNotarized,
                    title: "New & Not Notarized",
                    description: "Recently added app without Apple notarization - investigate source",
                    points: 15,
                    severity: .medium
                ))
            }
            // Don't flag older non-notarized apps - they're probably just pre-Catalina
        }

        // 5. Check for recently added items - DISABLED (too noisy)
        // Being recently added alone isn't suspicious
        // if let modDate = item.plistModifiedAt {
        //     if let flag = checkRecentlyAdded(date: modDate) {
        //         flags.append(flag)
        //     }
        // }

        // 6. Check for suspicious naming patterns
        if let flag = checkSuspiciousName(item: item) {
            flags.append(flag)
        }

        // 7. Check for hidden/unusual locations
        if let flag = checkHiddenLocation(item: item) {
            flags.append(flag)
        }

        // 8. Check for mismatched info - DISABLED (too many edge cases)
        // Many legitimate apps have org names that don't match app names
        // if let flag = checkMismatchedInfo(item: item) {
        //     flags.append(flag)
        // }

        // Calculate overall risk
        let totalPoints = flags.reduce(0) { $0 + $1.points }
        let overallRisk: AnalysisResult.RiskLevel
        switch totalPoints {
        case 0: overallRisk = .safe
        case 1..<20: overallRisk = .lowRisk
        case 20..<40: overallRisk = .suspicious
        case 40..<60: overallRisk = .dangerous
        default: overallRisk = .critical
        }

        let summary = generateSummary(flags: flags, risk: overallRisk)

        return AnalysisResult(flags: flags, overallRisk: overallRisk, summary: summary)
    }

    /// Extract entitlements from a binary using codesign
    private func extractEntitlements(from binaryPath: URL) -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", ":-", binaryPath.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return plist
            }
        } catch {
            // Ignore errors - binary might not have entitlements
        }

        return [:]
    }

    // MARK: - Private Checks

    private func checkCertificateAge(expirationDate: Date, sig: SignatureInfo) -> DangerFlag? {
        // Developer certificates are valid for ~1 year
        // If expiration is far in future, cert was recently issued
        let now = Date()
        let calendar = Calendar.current

        // Estimate issue date (certs valid for ~365 days)
        let estimatedIssueDate = calendar.date(byAdding: .day, value: -365, to: expirationDate) ?? expirationDate
        let daysSinceIssue = calendar.dateComponents([.day], from: estimatedIssueDate, to: now).day ?? 0

        if daysSinceIssue < 30 {
            return DangerFlag(
                type: .recentCertificate,
                title: "Very Recent Certificate",
                description: "Developer certificate issued ~\(daysSinceIssue) days ago - new/throwaway account?",
                points: 25,
                severity: .high
            )
        } else if daysSinceIssue < 90 {
            return DangerFlag(
                type: .recentCertificate,
                title: "Recent Certificate",
                description: "Developer certificate issued ~\(daysSinceIssue) days ago",
                points: 10,
                severity: .medium
            )
        }

        return nil
    }

    private func checkTeamIDReputation(teamID: String, orgName: String?) -> DangerFlag? {
        // Check against known trusted Team IDs
        if trustedTeamIDs.contains(teamID) {
            return nil // Known trusted vendor
        }

        // Check if org name suggests legitimate company
        let org = (orgName ?? "").lowercased()
        let legitimatePatterns = ["inc", "llc", "ltd", "corp", "gmbh", "s.r.l", "software", "technologies", "labs", "studio", "systems"]
        let hasLegitimatePattern = legitimatePatterns.contains { org.contains($0) }

        // If it looks like a legitimate company, don't flag it
        // We'll only flag truly suspicious cases
        if hasLegitimatePattern {
            return nil // Looks legitimate, no flag
        }

        // Check for personal developer accounts (just a name, no company suffix)
        // These are more common for indie apps, not necessarily suspicious
        let words = org.split(separator: " ")
        if words.count <= 3 && !org.isEmpty {
            // Looks like a personal name - only flag if combined with other factors
            // We'll return nil here and let other checks catch truly suspicious items
            return nil
        }

        // Only flag if org name is empty or very suspicious
        if org.isEmpty || org.count < 3 {
            return DangerFlag(
                type: .unknownTeamID,
                title: "Anonymous Developer",
                description: "No organization name provided for Team ID '\(teamID)'",
                points: 10,
                severity: .low
            )
        }

        return nil // Don't flag just because we don't know them
    }

    private func checkEntitlements(item: PersistenceItem, entitlements: [String: Any]) -> [DangerFlag] {
        var flags: [DangerFlag] = []

        guard !entitlements.isEmpty else { return flags }

        for (key, dangerInfo) in dangerousEntitlements {
            if entitlements[key] != nil {
                // Check if this entitlement makes sense for this type of app
                let isExpected = isEntitlementExpectedFor(item: item, entitlement: key)

                if !isExpected {
                    let points: Int
                    switch dangerInfo.severity {
                    case .critical: points = 30
                    case .high: points = 20
                    case .medium: points = 10
                    case .low: points = 5
                    case .info: points = 2
                    }

                    flags.append(DangerFlag(
                        type: .dangerousEntitlement,
                        title: dangerInfo.name,
                        description: dangerInfo.description,
                        points: points,
                        severity: dangerInfo.severity
                    ))
                }
            }
        }

        return flags
    }

    private func isEntitlementExpectedFor(item: PersistenceItem, entitlement: String) -> Bool {
        let name = item.name.lowercased()
        let identifier = item.identifier.lowercased()

        // Security tools can have security entitlements
        let securityTools = ["security", "antivirus", "malware", "sentinel", "crowdstrike", "carbon", "defender"]
        let isSecurityTool = securityTools.contains { name.contains($0) || identifier.contains($0) }

        // Development tools can have debug entitlements
        let devTools = ["xcode", "lldb", "debug", "developer", "instruments", "dtrace"]
        let isDevTool = devTools.contains { name.contains($0) || identifier.contains($0) }

        // Virtualization can have special entitlements
        let virtTools = ["virtual", "vmware", "parallels", "docker", "qemu", "hypervisor"]
        let isVirtTool = virtTools.contains { name.contains($0) || identifier.contains($0) }

        switch entitlement {
        case "com.apple.security.cs.debugger", "com.apple.security.get-task-allow":
            return isDevTool
        case "com.apple.developer.endpoint-security.client", "com.apple.developer.system-extension.install":
            return isSecurityTool
        case "com.apple.security.cs.allow-unsigned-executable-memory":
            return isDevTool || isVirtTool || name.contains("java") || name.contains("python")
        default:
            return false
        }
    }

    private func checkRecentlyAdded(date: Date) -> DangerFlag? {
        let daysSinceAdded = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0

        if daysSinceAdded <= 1 {
            return DangerFlag(
                type: .recentlyAdded,
                title: "Added Today",
                description: "Persistence item added in the last 24 hours",
                points: 10,
                severity: .medium
            )
        } else if daysSinceAdded <= 7 {
            return DangerFlag(
                type: .recentlyAdded,
                title: "Recently Added",
                description: "Persistence item added \(daysSinceAdded) days ago",
                points: 5,
                severity: .low
            )
        }

        return nil
    }

    private func checkSuspiciousName(item: PersistenceItem) -> DangerFlag? {
        guard let sig = item.signatureInfo else { return nil }

        let name = item.name.lowercased()
        let identifier = item.identifier.lowercased()

        // Only check impersonation if NOT Apple-signed
        if !sig.isAppleSigned {
            // Check for com.apple. prefix in non-Apple signed items (VERY suspicious)
            if identifier.hasPrefix("com.apple.") {
                return DangerFlag(
                    type: .suspiciousName,
                    title: "Apple Impersonation",
                    description: "Uses 'com.apple.' prefix but NOT signed by Apple - likely malware!",
                    points: 35,
                    severity: .critical
                )
            }
        }

        // Check for random-looking identifiers (e.g., "com.abc123xyz789.agent")
        let parts = identifier.split(separator: ".")
        for part in parts {
            let str = String(part)
            // Skip common patterns
            if ["com", "org", "net", "io", "app", "mac", "macos"].contains(str) {
                continue
            }
            // Check if it looks like random hex/base64
            if str.count >= 16 {
                let letterCount = str.filter { $0.isLetter }.count
                let digitCount = str.filter { $0.isNumber }.count
                let ratio = Double(digitCount) / Double(max(letterCount, 1))
                // If roughly equal mix of letters and numbers, suspicious
                if ratio > 0.3 && ratio < 3.0 && str.count > 20 {
                    return DangerFlag(
                        type: .suspiciousName,
                        title: "Random-looking Identifier",
                        description: "Bundle ID contains suspicious random-looking string",
                        points: 15,
                        severity: .medium
                    )
                }
            }
        }

        return nil
    }

    private func checkHiddenLocation(item: PersistenceItem) -> DangerFlag? {
        guard let path = item.plistPath?.path ?? item.executablePath?.path else { return nil }

        // Check for hidden directories
        if path.contains("/.") && !path.contains("/.Trash") {
            return DangerFlag(
                type: .hiddenLocation,
                title: "Hidden Directory",
                description: "Located in hidden directory - attempting to avoid detection",
                points: 20,
                severity: .high
            )
        }

        // Check for unusual locations
        let unusualPaths = ["/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/"]
        for unusual in unusualPaths {
            if path.hasPrefix(unusual) {
                return DangerFlag(
                    type: .hiddenLocation,
                    title: "Unusual Location",
                    description: "Located in '\(unusual)' - not standard persistence location",
                    points: 15,
                    severity: .medium
                )
            }
        }

        return nil
    }

    private func checkMismatchedInfo(item: PersistenceItem) -> DangerFlag? {
        guard let sig = item.signatureInfo,
              let orgName = sig.organizationName else { return nil }

        let org = orgName.lowercased()
        let name = item.name.lowercased()
        let identifier = item.identifier.lowercased()

        // Check for obvious mismatches (e.g., "Apple Inc" but identifier is "com.malware.xxx")
        if org.contains("apple") && !identifier.contains("apple") && !sig.isAppleSigned {
            return DangerFlag(
                type: .mismatchedInfo,
                title: "Org/ID Mismatch",
                description: "Claims to be from '\(orgName)' but identifier doesn't match",
                points: 25,
                severity: .high
            )
        }

        // Check if well-known company name but unknown team ID
        let wellKnownCompanies = ["microsoft", "google", "adobe", "oracle", "vmware", "docker"]
        for company in wellKnownCompanies {
            if (org.contains(company) || name.contains(company)) && !trustedTeamIDs.contains(sig.teamIdentifier ?? "") {
                return DangerFlag(
                    type: .mismatchedInfo,
                    title: "Possible Impersonation",
                    description: "References '\(company)' but Team ID is not the official one",
                    points: 20,
                    severity: .high
                )
            }
        }

        return nil
    }

    private func generateSummary(flags: [DangerFlag], risk: AnalysisResult.RiskLevel) -> String {
        if flags.isEmpty {
            return "No suspicious indicators detected for this signed application."
        }

        let criticalCount = flags.filter { $0.severity == .critical }.count
        let highCount = flags.filter { $0.severity == .high }.count

        if criticalCount > 0 {
            return "⚠️ CRITICAL: \(criticalCount) critical issue(s) detected. Strongly recommend investigation."
        } else if highCount > 0 {
            return "⚠️ WARNING: \(highCount) high-severity indicator(s). Review recommended."
        } else {
            return "Some minor indicators detected. May warrant review."
        }
    }
}
