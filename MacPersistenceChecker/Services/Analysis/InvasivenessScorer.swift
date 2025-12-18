import Foundation

/// Comprehensive scoring system for app invasiveness
struct InvasivenessScorer {

    // MARK: - Score Results

    struct ScoreResult {
        var persistenceScore: Int = 0      // 0-100: How invasive is the persistence
        var junkScore: Int = 0             // 0-100: How much junk is installed
        var totalScore: Int = 0            // Combined score

        var persistenceDetails: [ScoreDetail] = []
        var junkDetails: [ScoreDetail] = []

        var grade: InvasivenessGrade {
            InvasivenessGrade.from(score: totalScore)
        }
    }

    struct ScoreDetail {
        let category: String
        let description: String
        let points: Int
        let severity: Severity

        enum Severity: String {
            case low = "Low"
            case medium = "Medium"
            case high = "High"
            case critical = "Critical"
        }
    }

    // MARK: - Calculate Persistence Score

    /// Calculate persistence score based on triggers, privileges, resilience, redundancy
    static func calculatePersistenceScore(items: [PersistenceItem]) -> (score: Int, details: [ScoreDetail]) {
        var score = 0
        var details: [ScoreDetail] = []

        for item in items {
            // Skip Apple items
            if item.trustLevel == .apple { continue }

            var itemScore = 0
            var itemDetails: [ScoreDetail] = []

            // 1. TRIGGER TYPE SCORING
            let triggerResult = scoreTriggers(item)
            itemScore += triggerResult.score
            itemDetails.append(contentsOf: triggerResult.details)

            // 2. PRIVILEGE LEVEL SCORING
            let privilegeResult = scorePrivileges(item)
            itemScore += privilegeResult.score
            itemDetails.append(contentsOf: privilegeResult.details)

            // 3. RESILIENCE SCORING (auto-restart, relaunch)
            let resilienceResult = scoreResilience(item)
            itemScore += resilienceResult.score
            itemDetails.append(contentsOf: resilienceResult.details)

            // 4. EXECUTION FREQUENCY
            let frequencyResult = scoreFrequency(item)
            itemScore += frequencyResult.score
            itemDetails.append(contentsOf: frequencyResult.details)

            // 5. TRUST/SIGNATURE PENALTY
            let trustResult = scoreTrust(item)
            itemScore += trustResult.score
            itemDetails.append(contentsOf: trustResult.details)

            details.append(contentsOf: itemDetails)
        }

        // 6. REDUNDANCY SCORING (multiple items doing similar things)
        let redundancyResult = scoreRedundancy(items)
        score += redundancyResult.score
        details.append(contentsOf: redundancyResult.details)

        // Add item scores
        score += min(80, details.reduce(0) { $0 + $1.points })

        return (min(100, score), details)
    }

    // MARK: - Trigger Scoring

    private static func scoreTriggers(_ item: PersistenceItem) -> (score: Int, details: [ScoreDetail]) {
        var score = 0
        var details: [ScoreDetail] = []

        // RunAtLoad - runs every boot/login
        if item.runAtLoad == true {
            score += 15
            details.append(ScoreDetail(
                category: "Trigger",
                description: "\(item.name): RunAtLoad enabled - starts at every boot",
                points: 15,
                severity: .high
            ))
        }

        // KeepAlive - constantly running, restarts if killed
        if item.keepAlive == true {
            score += 20
            details.append(ScoreDetail(
                category: "Trigger",
                description: "\(item.name): KeepAlive enabled - always running, auto-restarts",
                points: 20,
                severity: .critical
            ))
        }

        // Note: watchPaths and startInterval would require parsing the plist
        // For now, we score based on the available properties

        return (score, details)
    }

    // MARK: - Privilege Scoring

    private static func scorePrivileges(_ item: PersistenceItem) -> (score: Int, details: [ScoreDetail]) {
        var score = 0
        var details: [ScoreDetail] = []

        // LaunchDaemons run as root
        if item.category == .launchDaemons {
            score += 20
            details.append(ScoreDetail(
                category: "Privilege",
                description: "\(item.name): LaunchDaemon - runs as ROOT",
                points: 20,
                severity: .critical
            ))
        }

        // Privileged Helpers have elevated access
        if item.category == .privilegedHelpers {
            score += 25
            details.append(ScoreDetail(
                category: "Privilege",
                description: "\(item.name): Privileged Helper - elevated system access",
                points: 25,
                severity: .critical
            ))
        }

        // Kernel Extensions - kernel level
        if item.category == .kernelExtensions {
            score += 30
            details.append(ScoreDetail(
                category: "Privilege",
                description: "\(item.name): Kernel Extension - kernel-level access",
                points: 30,
                severity: .critical
            ))
        }

        // System Extensions
        if item.category == .systemExtensions {
            score += 15
            details.append(ScoreDetail(
                category: "Privilege",
                description: "\(item.name): System Extension",
                points: 15,
                severity: .high
            ))
        }

        return (score, details)
    }

    // MARK: - Resilience Scoring

    private static func scoreResilience(_ item: PersistenceItem) -> (score: Int, details: [ScoreDetail]) {
        var score = 0
        var details: [ScoreDetail] = []

        // KeepAlive means auto-relaunch
        if item.keepAlive == true {
            score += 10
            details.append(ScoreDetail(
                category: "Resilience",
                description: "\(item.name): Auto-relaunches if terminated",
                points: 10,
                severity: .high
            ))
        }

        // Check if there's a helper/installer that could reinstall
        let identifier = item.identifier.lowercased()
        if identifier.contains("installer") || identifier.contains("updater") || identifier.contains("helper") {
            score += 5
            details.append(ScoreDetail(
                category: "Resilience",
                description: "\(item.name): May auto-reinstall (helper/updater)",
                points: 5,
                severity: .medium
            ))
        }

        return (score, details)
    }

    // MARK: - Frequency Scoring

    private static func scoreFrequency(_ item: PersistenceItem) -> (score: Int, details: [ScoreDetail]) {
        var score = 0
        var details: [ScoreDetail] = []

        // Constant execution (KeepAlive + RunAtLoad)
        if item.keepAlive == true && item.runAtLoad == true {
            score += 8
            details.append(ScoreDetail(
                category: "Frequency",
                description: "\(item.name): Constant execution - always active",
                points: 8,
                severity: .high
            ))
        }

        return (score, details)
    }

    // MARK: - Trust Scoring

    private static func scoreTrust(_ item: PersistenceItem) -> (score: Int, details: [ScoreDetail]) {
        var score = 0
        var details: [ScoreDetail] = []

        switch item.trustLevel {
        case .unsigned:
            score += 15
            details.append(ScoreDetail(
                category: "Trust",
                description: "\(item.name): UNSIGNED - no code signature",
                points: 15,
                severity: .high
            ))
        case .suspicious:
            score += 25
            details.append(ScoreDetail(
                category: "Trust",
                description: "\(item.name): SUSPICIOUS signature",
                points: 25,
                severity: .critical
            ))
        case .unknown:
            score += 5
            details.append(ScoreDetail(
                category: "Trust",
                description: "\(item.name): Unknown trust level",
                points: 5,
                severity: .low
            ))
        default:
            break
        }

        return (score, details)
    }

    // MARK: - Redundancy Scoring

    private static func scoreRedundancy(_ items: [PersistenceItem]) -> (score: Int, details: [ScoreDetail]) {
        var score = 0
        var details: [ScoreDetail] = []

        // Group by vendor/prefix
        var vendorCounts: [String: Int] = [:]
        for item in items {
            let parts = item.identifier.lowercased().components(separatedBy: ".")
            if parts.count >= 2 {
                let vendor = parts.prefix(2).joined(separator: ".")
                vendorCounts[vendor, default: 0] += 1
            }
        }

        // Penalize vendors with many items
        for (vendor, count) in vendorCounts where count > 3 {
            let redundancyScore = min(15, (count - 3) * 3)
            score += redundancyScore
            details.append(ScoreDetail(
                category: "Redundancy",
                description: "\(vendor): \(count) persistence items (excessive)",
                points: redundancyScore,
                severity: count > 5 ? .high : .medium
            ))
        }

        return (score, details)
    }

    // MARK: - Calculate Junk Score

    /// Calculate junk score based on installation quality
    static func calculateJunkScore(
        appName: String,
        junkInfo: AppJunkInfo?,
        hasMatchingApp: Bool,
        persistenceItems: [PersistenceItem]
    ) -> (score: Int, details: [ScoreDetail]) {
        var score = 0
        var details: [ScoreDetail] = []

        guard let junk = junkInfo else { return (0, []) }

        // 1. FILE SPREAD - files in many locations
        let locationCount = junk.locations.count
        if locationCount > 5 {
            let spreadScore = min(20, (locationCount - 5) * 2)
            score += spreadScore
            details.append(ScoreDetail(
                category: "File Spread",
                description: "\(appName): Files in \(locationCount) different locations",
                points: spreadScore,
                severity: locationCount > 10 ? .high : .medium
            ))
        }

        // 2. TOTAL SIZE
        let sizeGB = Double(junk.totalSize) / 1_000_000_000
        if sizeGB > 1 {
            let sizeScore = min(25, Int(sizeGB * 10))
            score += sizeScore
            details.append(ScoreDetail(
                category: "Size",
                description: "\(appName): \(junk.formattedSize) of data",
                points: sizeScore,
                severity: sizeGB > 5 ? .critical : .high
            ))
        } else if junk.totalSize > 100_000_000 { // > 100MB
            score += 10
            details.append(ScoreDetail(
                category: "Size",
                description: "\(appName): \(junk.formattedSize) of data",
                points: 10,
                severity: .medium
            ))
        }

        // 3. ORPHAN CHECK - persistence without matching app
        if !hasMatchingApp && !persistenceItems.isEmpty {
            score += 20
            details.append(ScoreDetail(
                category: "Orphan",
                description: "\(appName): Persistence items with NO matching app installed",
                points: 20,
                severity: .high
            ))
        }

        // 4. OPAQUE VENDOR - hard to identify source
        let nameLower = appName.lowercased()
        let opaquePatterns = ["helper", "agent", "daemon", "service", "updater", "sync"]
        if opaquePatterns.contains(where: { nameLower.contains($0) }) && !hasMatchingApp {
            score += 10
            details.append(ScoreDetail(
                category: "Opaque",
                description: "\(appName): Generic name, unclear origin",
                points: 10,
                severity: .medium
            ))
        }

        // 5. CACHE BLOAT - excessive cache usage
        let cacheLocations = junk.locations.filter { $0.type.contains("Cache") }
        let cacheSize = cacheLocations.reduce(Int64(0)) { $0 + $1.size }
        if cacheSize > 500_000_000 { // > 500MB cache
            let cacheScore = min(15, Int(Double(cacheSize) / 500_000_000) * 5)
            score += cacheScore
            details.append(ScoreDetail(
                category: "Cache Bloat",
                description: "\(appName): \(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)) in caches",
                points: cacheScore,
                severity: .medium
            ))
        }

        // 6. SYSTEM LOCATIONS - files in /Library (system-wide)
        let systemLocations = junk.locations.filter { $0.path.hasPrefix("/Library") }
        if !systemLocations.isEmpty {
            score += systemLocations.count * 3
            details.append(ScoreDetail(
                category: "System Install",
                description: "\(appName): \(systemLocations.count) items in system Library",
                points: systemLocations.count * 3,
                severity: .medium
            ))
        }

        return (min(100, score), details)
    }

    // MARK: - Combined Score

    /// Calculate combined score for an app
    static func calculateTotalScore(
        appName: String,
        persistenceItems: [PersistenceItem],
        junkInfo: AppJunkInfo?,
        hasMatchingApp: Bool
    ) -> ScoreResult {
        var result = ScoreResult()

        // Calculate persistence score
        let persistenceResult = calculatePersistenceScore(items: persistenceItems)
        result.persistenceScore = persistenceResult.score
        result.persistenceDetails = persistenceResult.details

        // Calculate junk score
        let junkResult = calculateJunkScore(
            appName: appName,
            junkInfo: junkInfo,
            hasMatchingApp: hasMatchingApp,
            persistenceItems: persistenceItems
        )
        result.junkScore = junkResult.score
        result.junkDetails = junkResult.details

        // Combined score (weighted average)
        // Persistence is more concerning than junk
        result.totalScore = min(100, (result.persistenceScore * 6 + result.junkScore * 4) / 10)

        return result
    }
}
