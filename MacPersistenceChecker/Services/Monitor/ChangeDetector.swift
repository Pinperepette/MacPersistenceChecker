import Foundation

/// Detects and scores changes between baseline and current state
final class ChangeDetector {

    // MARK: - Public Methods

    /// Detect changes between baseline and current items for a category
    func detectChanges(
        baseline: [PersistenceItem],
        current: [PersistenceItem],
        category: PersistenceCategory
    ) -> [MonitorChange] {
        var changes: [MonitorChange] = []

        // Use uniquingKeysWith to handle duplicate identifiers (keep first occurrence)
        let baselineDict = Dictionary(baseline.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let currentDict = Dictionary(current.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })

        // Find added items
        for (identifier, item) in currentDict {
            if baselineDict[identifier] == nil {
                changes.append(MonitorChange(
                    type: .added,
                    item: item,
                    category: category,
                    timestamp: Date(),
                    details: [MonitorChangeDetail(field: "New Item", oldValue: "", newValue: item.name)]
                ))
            }
        }

        // Find removed items
        for (identifier, item) in baselineDict {
            if currentDict[identifier] == nil {
                changes.append(MonitorChange(
                    type: .removed,
                    item: item,
                    category: category,
                    timestamp: Date(),
                    details: [MonitorChangeDetail(field: "Removed Item", oldValue: item.name, newValue: "")]
                ))
            }
        }

        // Find modified items
        for (identifier, currentItem) in currentDict {
            if let baselineItem = baselineDict[identifier] {
                let itemChanges = detectItemChanges(baseline: baselineItem, current: currentItem)
                if !itemChanges.isEmpty {
                    // Determine if it's an enable/disable change
                    let changeType: MonitorChangeType
                    if itemChanges.contains(where: { $0.field == "isEnabled" }) {
                        changeType = currentItem.isEnabled ? .enabled : .disabled
                    } else {
                        changeType = .modified
                    }

                    changes.append(MonitorChange(
                        type: changeType,
                        item: currentItem,
                        category: category,
                        timestamp: Date(),
                        details: itemChanges
                    ))
                }
            }
        }

        return changes
    }

    /// Calculate relevance score for a change (0-100)
    func calculateRelevance(_ change: MonitorChange) -> Int {
        var score = 0

        // Base score by change type
        switch change.type {
        case .added:
            score += 60  // New items are significant
        case .removed:
            score += 40  // Removals might be user-intended
        case .modified:
            score += 30  // Modifications need context
        case .enabled:
            score += 50  // Something was enabled
        case .disabled:
            score += 20  // Disabling is usually intentional
        }

        // Category sensitivity - higher for more critical categories
        score += categorySensitivity(change.category)

        // Trust level factors
        if let item = change.item {
            score += trustLevelScore(item.trustLevel)

            // Risk score factor
            if let riskScore = item.riskScore, riskScore > 50 {
                score += 15
            }

            // Unsigned binaries are more concerning
            if item.signatureInfo == nil {
                score += 10
            }
        }

        // Specific change factors
        if change.details.contains(where: { $0.field == "executablePath" }) {
            score += 15  // Executable changed - very significant
        }

        if change.details.contains(where: { $0.field == "programArguments" }) {
            score += 10  // Arguments changed
        }

        if change.details.contains(where: { $0.field == "runAtLoad" && $0.newValue == "true" }) {
            score += 10  // Now runs at load
        }

        return min(100, max(0, score))
    }

    // MARK: - Private Methods

    private func detectItemChanges(baseline: PersistenceItem, current: PersistenceItem) -> [MonitorChangeDetail] {
        var changes: [MonitorChangeDetail] = []

        // Check enabled state
        if baseline.isEnabled != current.isEnabled {
            changes.append(MonitorChangeDetail(
                field: "isEnabled",
                oldValue: String(baseline.isEnabled),
                newValue: String(current.isEnabled)
            ))
        }

        // Check loaded state
        if baseline.isLoaded != current.isLoaded {
            changes.append(MonitorChangeDetail(
                field: "isLoaded",
                oldValue: String(baseline.isLoaded),
                newValue: String(current.isLoaded)
            ))
        }

        // Check executable path
        if baseline.executablePath?.path != current.executablePath?.path {
            changes.append(MonitorChangeDetail(
                field: "executablePath",
                oldValue: baseline.executablePath?.path ?? "none",
                newValue: current.executablePath?.path ?? "none"
            ))
        }

        // Check binary modification date
        if let baselineDate = baseline.binaryModifiedAt,
           let currentDate = current.binaryModifiedAt,
           abs(baselineDate.timeIntervalSince(currentDate)) > 1 {  // 1 second tolerance
            changes.append(MonitorChangeDetail(
                field: "binaryModifiedAt",
                oldValue: formatDate(baselineDate),
                newValue: formatDate(currentDate)
            ))
        }

        // Check plist modification date
        if let baselineDate = baseline.plistModifiedAt,
           let currentDate = current.plistModifiedAt,
           abs(baselineDate.timeIntervalSince(currentDate)) > 1 {
            changes.append(MonitorChangeDetail(
                field: "plistModifiedAt",
                oldValue: formatDate(baselineDate),
                newValue: formatDate(currentDate)
            ))
        }

        // Check runAtLoad
        if baseline.runAtLoad != current.runAtLoad {
            changes.append(MonitorChangeDetail(
                field: "runAtLoad",
                oldValue: String(describing: baseline.runAtLoad ?? false),
                newValue: String(describing: current.runAtLoad ?? false)
            ))
        }

        // Check keepAlive
        if baseline.keepAlive != current.keepAlive {
            changes.append(MonitorChangeDetail(
                field: "keepAlive",
                oldValue: String(describing: baseline.keepAlive ?? false),
                newValue: String(describing: current.keepAlive ?? false)
            ))
        }

        // Check program arguments
        if baseline.programArguments != current.programArguments {
            changes.append(MonitorChangeDetail(
                field: "programArguments",
                oldValue: baseline.programArguments?.joined(separator: " ") ?? "none",
                newValue: current.programArguments?.joined(separator: " ") ?? "none"
            ))
        }

        // Check trust level change
        if baseline.trustLevel != current.trustLevel {
            changes.append(MonitorChangeDetail(
                field: "trustLevel",
                oldValue: baseline.trustLevel.rawValue,
                newValue: current.trustLevel.rawValue
            ))
        }

        return changes
    }

    private func categorySensitivity(_ category: PersistenceCategory) -> Int {
        switch category {
        case .launchDaemons:
            return 25  // System-level, runs as root
        case .launchAgents:
            return 20  // User-level but common attack vector
        case .kernelExtensions:
            return 30  // Kernel level - highest risk
        case .systemExtensions:
            return 25
        case .privilegedHelpers:
            return 25  // Elevated privileges
        case .authorizationPlugins:
            return 25  // Security-sensitive
        case .loginItems:
            return 15
        case .cronJobs:
            return 20
        case .shellStartupFiles:
            return 15
        case .tccAccessibility:
            return 20  // Privacy-sensitive
        case .dylibHijacking:
            return 25  // Code injection
        case .btmDatabase:
            return 15
        case .mdmProfiles:
            return 20
        case .periodicScripts:
            return 15
        case .loginHooks:
            return 15
        case .spotlightImporters, .quickLookPlugins:
            return 10
        case .directoryServicesPlugins:
            return 15
        case .finderSyncExtensions:
            return 10
        case .applicationSupport:
            return 10
        }
    }

    private func trustLevelScore(_ trustLevel: TrustLevel) -> Int {
        switch trustLevel {
        case .suspicious:
            return 30  // Definitely concerning
        case .unsigned:
            return 25  // No code signature
        case .signed:
            return 5   // Signed but unknown
        case .knownVendor:
            return 0   // Known vendor
        case .apple:
            return -20 // Apple items are expected
        case .unknown:
            return 10
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// MARK: - Change Summary

extension ChangeDetector {
    /// Generate a summary of multiple changes
    func summarizeChanges(_ changes: [MonitorChange]) -> String {
        let added = changes.filter { $0.type == .added }.count
        let removed = changes.filter { $0.type == .removed }.count
        let modified = changes.filter { $0.type == .modified || $0.type == .enabled || $0.type == .disabled }.count

        var parts: [String] = []
        if added > 0 { parts.append("+\(added) added") }
        if removed > 0 { parts.append("-\(removed) removed") }
        if modified > 0 { parts.append("~\(modified) modified") }

        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }

    /// Filter changes by minimum relevance score
    func filterByRelevance(_ changes: [MonitorChange], minimum: Int) -> [MonitorChange] {
        return changes.filter { calculateRelevance($0) >= minimum }
    }

    /// Sort changes by relevance (highest first)
    func sortByRelevance(_ changes: [MonitorChange]) -> [MonitorChange] {
        return changes.sorted { calculateRelevance($0) > calculateRelevance($1) }
    }
}
