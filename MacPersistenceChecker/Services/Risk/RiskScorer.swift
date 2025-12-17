import Foundation

/// Risk scoring system for persistence items
/// Score range: 0-100 (higher = more suspicious)
final class RiskScorer {

    // MARK: - Score Weights

    private enum Weight {
        // Path-based risks
        static let tmpPath: Int = 25
        static let privateVarPath: Int = 20
        static let userLibraryPath: Int = 10
        static let hiddenPath: Int = 15
        static let randomNamePath: Int = 20

        // Signature risks
        static let unsigned: Int = 30
        static let invalidSignature: Int = 25
        static let expiredCertificate: Int = 15
        static let noHardenedRuntime: Int = 10
        static let adHocSigned: Int = 20

        // Entitlement risks
        static let disableLibraryValidation: Int = 20
        static let allowDyldEnvVars: Int = 25
        static let getTaskAllow: Int = 15
        static let csAllowUnsignedExecutableMemory: Int = 20
        static let injectionDebugger: Int = 25

        // Behavior risks (LaunchAgent/Daemon)
        static let runAtLoadKeepAlive: Int = 15
        static let runAsRoot: Int = 10
        static let watchPaths: Int = 10
        static let startInterval: Int = 5

        // Binary analysis
        static let executableMissing: Int = 20
        static let recentlyModified: Int = 10
        static let unusualPermissions: Int = 15
    }

    // MARK: - Suspicious Entitlements

    static let suspiciousEntitlements: [String: Int] = [
        "com.apple.security.cs.disable-library-validation": Weight.disableLibraryValidation,
        "com.apple.security.cs.allow-dyld-environment-variables": Weight.allowDyldEnvVars,
        "com.apple.security.get-task-allow": Weight.getTaskAllow,
        "com.apple.security.cs.allow-unsigned-executable-memory": Weight.csAllowUnsignedExecutableMemory,
        "com.apple.security.cs.debugger": Weight.injectionDebugger,
        "com.apple.security.cs.allow-jit": Weight.getTaskAllow,
        "com.apple.security.automation.apple-events": 5,
        "com.apple.security.temporary-exception.mach-lookup.global-name": 10,
    ]

    // MARK: - Risk Detail

    struct RiskDetail: Codable, Equatable, Hashable {
        let factor: String
        let points: Int
        let description: String
    }

    struct RiskAssessment: Codable, Equatable, Hashable {
        let score: Int
        let details: [RiskDetail]
        let severity: RiskSeverity

        var normalizedScore: Double {
            return min(100.0, Double(score)) / 100.0
        }
    }

    enum RiskSeverity: String, Codable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"
        case critical = "Critical"

        static func from(score: Int) -> RiskSeverity {
            switch score {
            case 0..<25: return .low
            case 25..<50: return .medium
            case 50..<75: return .high
            default: return .critical
            }
        }
    }

    // MARK: - Main Scoring Method

    func assess(_ item: PersistenceItem, entitlements: [String: Any]? = nil) -> RiskAssessment {
        var totalScore = 0
        var details: [RiskDetail] = []

        // 1. Path-based analysis
        let pathRisks = assessPathRisks(item)
        totalScore += pathRisks.reduce(0) { $0 + $1.points }
        details.append(contentsOf: pathRisks)

        // 2. Signature analysis
        let signatureRisks = assessSignatureRisks(item)
        totalScore += signatureRisks.reduce(0) { $0 + $1.points }
        details.append(contentsOf: signatureRisks)

        // 3. Entitlements analysis
        let entitlementRisks = assessEntitlementRisks(entitlements)
        totalScore += entitlementRisks.reduce(0) { $0 + $1.points }
        details.append(contentsOf: entitlementRisks)

        // 4. Behavior analysis (LaunchAgent/Daemon specific)
        let behaviorRisks = assessBehaviorRisks(item)
        totalScore += behaviorRisks.reduce(0) { $0 + $1.points }
        details.append(contentsOf: behaviorRisks)

        // 5. Binary analysis
        let binaryRisks = assessBinaryRisks(item)
        totalScore += binaryRisks.reduce(0) { $0 + $1.points }
        details.append(contentsOf: binaryRisks)

        // Apply reduction for trusted signatures
        if item.signatureInfo?.isAppleSigned == true {
            totalScore = max(0, totalScore - 40)
        } else if item.signatureInfo?.isNotarized == true && item.signatureInfo?.isValid == true {
            totalScore = max(0, totalScore - 20)
        }

        let finalScore = min(100, totalScore)

        return RiskAssessment(
            score: finalScore,
            details: details,
            severity: .from(score: finalScore)
        )
    }

    // MARK: - Path Risk Assessment

    private func assessPathRisks(_ item: PersistenceItem) -> [RiskDetail] {
        var risks: [RiskDetail] = []

        let paths = [
            item.plistPath?.path,
            item.executablePath?.path,
            item.programArguments?.first
        ].compactMap { $0 }

        for path in paths {
            // /tmp or /private/tmp
            if path.hasPrefix("/tmp") || path.hasPrefix("/private/tmp") {
                risks.append(RiskDetail(
                    factor: "Suspicious Path",
                    points: Weight.tmpPath,
                    description: "Executable in /tmp directory"
                ))
                break
            }

            // /private/var (excluding standard locations)
            if path.hasPrefix("/private/var") && !path.contains("/private/var/db/") {
                risks.append(RiskDetail(
                    factor: "Suspicious Path",
                    points: Weight.privateVarPath,
                    description: "Executable in /private/var"
                ))
                break
            }

            // User Library (not standard app locations)
            if path.contains("/Users/") && path.contains("/Library/") {
                // Exclude legitimate locations
                if !path.contains("/Application Support/") &&
                   !path.contains("/Preferences/") &&
                   !path.contains("/LaunchAgents/") {
                    risks.append(RiskDetail(
                        factor: "User Library Path",
                        points: Weight.userLibraryPath,
                        description: "Executable in user Library folder"
                    ))
                    break
                }
            }

            // Hidden files/directories
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") && $0 != ".." }) {
                risks.append(RiskDetail(
                    factor: "Hidden Path",
                    points: Weight.hiddenPath,
                    description: "Hidden file or directory in path"
                ))
                break
            }

            // Random-looking name detection
            if hasRandomLookingName(path) {
                risks.append(RiskDetail(
                    factor: "Suspicious Name",
                    points: Weight.randomNamePath,
                    description: "Randomly generated filename pattern"
                ))
                break
            }
        }

        return risks
    }

    // MARK: - Signature Risk Assessment

    private func assessSignatureRisks(_ item: PersistenceItem) -> [RiskDetail] {
        var risks: [RiskDetail] = []

        guard let sig = item.signatureInfo else {
            // No signature info available
            risks.append(RiskDetail(
                factor: "Unsigned",
                points: Weight.unsigned,
                description: "No code signature"
            ))
            return risks
        }

        // Unsigned binary
        if !sig.isSigned {
            risks.append(RiskDetail(
                factor: "Unsigned",
                points: Weight.unsigned,
                description: "Binary is not signed"
            ))
            return risks
        }

        // Invalid signature
        if !sig.isValid {
            risks.append(RiskDetail(
                factor: "Invalid Signature",
                points: Weight.invalidSignature,
                description: "Code signature is invalid or tampered"
            ))
        }

        // Expired certificate
        if sig.isCertificateExpired {
            risks.append(RiskDetail(
                factor: "Expired Certificate",
                points: Weight.expiredCertificate,
                description: "Signing certificate has expired"
            ))
        }

        // No hardened runtime
        if !sig.hasHardenedRuntime && !sig.isAppleSigned {
            risks.append(RiskDetail(
                factor: "No Hardened Runtime",
                points: Weight.noHardenedRuntime,
                description: "Missing hardened runtime protection"
            ))
        }

        // Ad-hoc signed (self-signed without identity)
        if sig.isSigned && sig.teamIdentifier == nil && !sig.isAppleSigned {
            risks.append(RiskDetail(
                factor: "Ad-hoc Signature",
                points: Weight.adHocSigned,
                description: "Ad-hoc signed without developer identity"
            ))
        }

        return risks
    }

    // MARK: - Entitlements Risk Assessment

    private func assessEntitlementRisks(_ entitlements: [String: Any]?) -> [RiskDetail] {
        var risks: [RiskDetail] = []

        guard let ent = entitlements else {
            return risks
        }

        for (key, points) in Self.suspiciousEntitlements {
            if let value = ent[key] {
                // Check if entitlement is enabled (true or non-empty)
                let isEnabled: Bool
                if let boolValue = value as? Bool {
                    isEnabled = boolValue
                } else if let arrayValue = value as? [Any] {
                    isEnabled = !arrayValue.isEmpty
                } else {
                    isEnabled = true
                }

                if isEnabled {
                    let shortKey = key.replacingOccurrences(of: "com.apple.security.", with: "")
                    risks.append(RiskDetail(
                        factor: "Suspicious Entitlement",
                        points: points,
                        description: shortKey
                    ))
                }
            }
        }

        return risks
    }

    // MARK: - Behavior Risk Assessment

    private func assessBehaviorRisks(_ item: PersistenceItem) -> [RiskDetail] {
        var risks: [RiskDetail] = []

        // RunAtLoad + KeepAlive combo (persistent and auto-start)
        if item.runAtLoad == true && item.keepAlive == true {
            risks.append(RiskDetail(
                factor: "Persistent Auto-Start",
                points: Weight.runAtLoadKeepAlive,
                description: "RunAtLoad + KeepAlive ensures persistence"
            ))
        }

        // Check if running as root (system LaunchDaemon)
        if item.category == .launchDaemons {
            if let plistPath = item.plistPath?.path,
               plistPath.hasPrefix("/Library/LaunchDaemons") {
                // Third-party daemon running as root
                if item.signatureInfo?.isAppleSigned != true {
                    risks.append(RiskDetail(
                        factor: "Root Daemon",
                        points: Weight.runAsRoot,
                        description: "Third-party daemon runs as root"
                    ))
                }
            }
        }

        return risks
    }

    // MARK: - Binary Risk Assessment

    private func assessBinaryRisks(_ item: PersistenceItem) -> [RiskDetail] {
        var risks: [RiskDetail] = []

        // Executable doesn't exist
        if !item.executableExists && item.executablePath != nil {
            risks.append(RiskDetail(
                factor: "Missing Executable",
                points: Weight.executableMissing,
                description: "Referenced executable not found"
            ))
        }

        // Recently modified binary (within last 7 days)
        if let modDate = item.binaryModifiedAt {
            let daysSinceModification = Calendar.current.dateComponents(
                [.day],
                from: modDate,
                to: Date()
            ).day ?? 0

            if daysSinceModification <= 7 {
                risks.append(RiskDetail(
                    factor: "Recently Modified",
                    points: Weight.recentlyModified,
                    description: "Binary modified within last 7 days"
                ))
            }
        }

        // Check for unusual permissions
        if let execPath = item.executablePath?.path {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: execPath),
               let permissions = attrs[.posixPermissions] as? Int {
                // Check for world-writable
                if permissions & 0o002 != 0 {
                    risks.append(RiskDetail(
                        factor: "World-Writable",
                        points: Weight.unusualPermissions,
                        description: "Executable is world-writable"
                    ))
                }
            }
        }

        return risks
    }

    // MARK: - Helpers

    /// Detect random-looking filenames (common in malware)
    private func hasRandomLookingName(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent
        let nameWithoutExt = (filename as NSString).deletingPathExtension

        // Skip very short names
        guard nameWithoutExt.count >= 8 else { return false }

        // Check for high entropy / random patterns
        let consonants = CharacterSet(charactersIn: "bcdfghjklmnpqrstvwxyzBCDFGHJKLMNPQRSTVWXYZ")
        let vowels = CharacterSet(charactersIn: "aeiouAEIOU")

        var consonantCount = 0
        var vowelCount = 0
        var digitCount = 0

        for char in nameWithoutExt.unicodeScalars {
            if consonants.contains(char) {
                consonantCount += 1
            } else if vowels.contains(char) {
                vowelCount += 1
            } else if CharacterSet.decimalDigits.contains(char) {
                digitCount += 1
            }
        }

        let totalLetters = consonantCount + vowelCount
        guard totalLetters > 0 else { return false }

        // Suspicious patterns:
        // 1. Very low vowel ratio (random strings)
        let vowelRatio = Double(vowelCount) / Double(totalLetters)
        if vowelRatio < 0.1 && nameWithoutExt.count > 10 {
            return true
        }

        // 2. High digit ratio mixed with letters
        let digitRatio = Double(digitCount) / Double(nameWithoutExt.count)
        if digitRatio > 0.3 && totalLetters > 5 {
            return true
        }

        // 3. Looks like UUID/hash
        let uuidPattern = try? NSRegularExpression(
            pattern: "^[a-fA-F0-9]{8,}$|^[a-fA-F0-9-]{32,}$"
        )
        if let pattern = uuidPattern {
            let range = NSRange(nameWithoutExt.startIndex..., in: nameWithoutExt)
            if pattern.firstMatch(in: nameWithoutExt, range: range) != nil {
                return true
            }
        }

        return false
    }
}

// MARK: - Entitlements Extractor

extension RiskScorer {
    /// Extract entitlements from a binary
    static func extractEntitlements(from binaryURL: URL) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", "-", "--xml", binaryURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard !data.isEmpty else { return nil }

            // Parse plist
            if let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] {
                return plist
            }
        } catch {
            return nil
        }

        return nil
    }
}
