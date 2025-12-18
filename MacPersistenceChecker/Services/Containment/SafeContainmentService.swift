import Foundation
import Combine

/// Main service for safe containment of persistence items
/// Provides EDR-like functionality: disable persistence, block network, preserve binary, log everything
@MainActor
final class SafeContainmentService: ObservableObject {
    static let shared = SafeContainmentService()

    /// Published containment states for UI updates
    @Published private(set) var containedItems: Set<String> = []

    /// Active containment states by item identifier
    @Published private(set) var containmentStates: [String: ContainmentState] = [:]

    private let networkBlocker = NetworkBlocker.shared
    private let db = DatabaseManager.shared

    /// Default containment timeout (24 hours)
    let defaultTimeout: TimeInterval = 86400

    private init() {
        // Load active containments on init
        Task {
            await loadActiveContainments()
        }

        // Setup network blocker callback
        networkBlocker.onRuleExpired = { [weak self] rule in
            Task { @MainActor in
                self?.handleRuleExpired(rule)
            }
        }
    }

    // MARK: - Public Interface

    /// Full containment: disable persistence + block network
    func containItem(_ item: PersistenceItem, timeout: TimeInterval? = nil) async -> ContainmentResult {
        let effectiveTimeout = timeout ?? defaultTimeout

        // Check if already contained
        if containedItems.contains(item.identifier) {
            return .failure(.alreadyContained)
        }

        var warnings: [String] = []
        var persistenceDisabled = false
        var networkBlocked = false
        var networkRule: NetworkRule?
        var binaryHash: String?
        var plistBackup: String?

        // 1. Calculate binary hash for integrity verification
        if let binaryPath = item.effectiveExecutablePath {
            binaryHash = networkBlocker.hashBinary(binaryPath)
        }

        // 2. Backup and disable persistence
        if let plistPath = item.plistPath {
            let backupResult = await disablePersistence(item)
            switch backupResult {
            case .success(let backup):
                plistBackup = backup
                persistenceDisabled = true
            case .failure(let error):
                warnings.append("Persistence disable failed: \(error.localizedDescription)")
            }
        } else {
            warnings.append("No plist found - skipping persistence disable")
        }

        // 3. Block network
        if let binaryPath = item.effectiveExecutablePath {
            let blockResult = await networkBlocker.blockBinary(binaryPath, timeout: effectiveTimeout)
            switch blockResult {
            case .success(let rule):
                networkRule = rule
                networkBlocked = true
                // Save rule to database
                try? db.saveNetworkRule(rule, itemIdentifier: item.identifier)
            case .failure(let error):
                warnings.append("Network block failed: \(error.localizedDescription)")
            }
        } else {
            warnings.append("No binary found - skipping network block")
        }

        // 4. Determine overall status
        let status: ContainmentStatus
        if persistenceDisabled && networkBlocked {
            status = .active
        } else if persistenceDisabled || networkBlocked {
            status = .partial
        } else {
            return .failure(.unknown("Both persistence disable and network block failed"))
        }

        // 5. Create and save action record
        let expiresAt = Date().addingTimeInterval(effectiveTimeout)
        let action = ContainmentAction.contain(
            item: item,
            binaryHash: binaryHash,
            plistBackup: plistBackup,
            networkRule: networkRule,
            expiresAt: expiresAt,
            status: status,
            details: [
                "persistenceDisabled": persistenceDisabled,
                "networkBlocked": networkBlocked,
                "timeout": effectiveTimeout
            ]
        )

        do {
            let savedAction = try db.saveContainmentAction(action)

            // Update state
            let state = ContainmentState(
                isContained: true,
                persistenceDisabled: persistenceDisabled,
                networkBlocked: networkBlocked,
                networkRule: networkRule,
                binaryHash: binaryHash,
                containedAt: Date(),
                expiresAt: expiresAt
            )
            containmentStates[item.identifier] = state
            containedItems.insert(item.identifier)

            if status == .partial {
                return .partial(savedAction, error: .unknown("Partial containment"), warnings: warnings)
            }
            return .success(savedAction, warnings: warnings)

        } catch {
            return .failure(.databaseError(error.localizedDescription))
        }
    }

    /// Disable persistence only (without network block)
    func disablePersistenceOnly(_ item: PersistenceItem) async -> ContainmentResult {
        guard let plistPath = item.plistPath else {
            return .failure(.plistNotFound)
        }

        let result = await disablePersistence(item)

        switch result {
        case .success(let plistBackup):
            let action = ContainmentAction.persistenceDisable(
                item: item,
                plistBackup: plistBackup,
                status: .active
            )

            do {
                let savedAction = try db.saveContainmentAction(action)

                // Update state
                var state = containmentStates[item.identifier] ?? .none
                state.isContained = true
                state.persistenceDisabled = true
                state.containedAt = Date()
                containmentStates[item.identifier] = state
                containedItems.insert(item.identifier)

                return .success(savedAction)
            } catch {
                return .failure(.databaseError(error.localizedDescription))
            }

        case .failure(let error):
            return .failure(error)
        }
    }

    /// Block network only (without disabling persistence)
    func blockNetworkOnly(_ item: PersistenceItem, timeout: TimeInterval? = nil) async -> ContainmentResult {
        guard let binaryPath = item.effectiveExecutablePath else {
            return .failure(.binaryNotFound)
        }

        let effectiveTimeout = timeout ?? defaultTimeout
        let result = await networkBlocker.blockBinary(binaryPath, timeout: effectiveTimeout)

        switch result {
        case .success(let rule):
            // Save rule to database
            try? db.saveNetworkRule(rule, itemIdentifier: item.identifier)

            let expiresAt = Date().addingTimeInterval(effectiveTimeout)
            let action = ContainmentAction.networkBlock(
                item: item,
                networkRule: rule,
                expiresAt: expiresAt,
                status: .active
            )

            do {
                let savedAction = try db.saveContainmentAction(action)

                // Update state
                var state = containmentStates[item.identifier] ?? .none
                state.isContained = true
                state.networkBlocked = true
                state.networkRule = rule
                state.containedAt = Date()
                state.expiresAt = expiresAt
                containmentStates[item.identifier] = state
                containedItems.insert(item.identifier)

                return .success(savedAction)
            } catch {
                return .failure(.databaseError(error.localizedDescription))
            }

        case .failure(let error):
            return .failure(error)
        }
    }

    /// Release item from containment
    func releaseItem(_ item: PersistenceItem) async -> ContainmentResult {
        guard containedItems.contains(item.identifier) else {
            return .failure(.notContained)
        }

        var warnings: [String] = []

        // Get current state
        guard let state = containmentStates[item.identifier],
              let activeContainment = try? db.getActiveContainment(for: item.identifier) else {
            return .failure(.notContained)
        }

        // 1. Re-enable persistence if it was disabled
        if state.persistenceDisabled {
            let enableResult = await enablePersistence(item, plistBackup: activeContainment.plistBackup)
            if case .failure(let error) = enableResult {
                warnings.append("Failed to re-enable persistence: \(error.localizedDescription)")
            }
        }

        // 2. Unblock network if it was blocked
        if let networkRule = state.networkRule {
            let unblockResult = await networkBlocker.unblockBinary(rule: networkRule)
            if case .failure(let error) = unblockResult {
                warnings.append("Failed to unblock network: \(error.localizedDescription)")
            }
            // Remove rule from database
            try? db.removeNetworkRule(id: networkRule.id)
        }

        // 3. Create release action record
        let releaseAction = ContainmentAction.release(item: item, previousAction: activeContainment)

        do {
            let savedAction = try db.saveContainmentAction(releaseAction)

            // Update previous action status
            if let actionId = activeContainment.id {
                try? db.updateContainmentStatus(id: actionId, status: .released)
            }

            // Clear state
            containmentStates.removeValue(forKey: item.identifier)
            containedItems.remove(item.identifier)

            return .success(savedAction, warnings: warnings)

        } catch {
            return .failure(.databaseError(error.localizedDescription))
        }
    }

    /// Extend containment timeout
    func extendTimeout(_ item: PersistenceItem, additionalTime: TimeInterval = 86400) async -> ContainmentResult {
        guard var state = containmentStates[item.identifier] else {
            return .failure(.notContained)
        }

        let newExpiresAt = (state.expiresAt ?? Date()).addingTimeInterval(additionalTime)
        state.expiresAt = newExpiresAt
        containmentStates[item.identifier] = state

        // If network is blocked, update the rule
        if let rule = state.networkRule {
            // Remove old rule and create new one with extended timeout
            _ = await networkBlocker.unblockBinary(rule: rule)
            try? db.removeNetworkRule(id: rule.id)

            if let binaryPath = item.effectiveExecutablePath {
                let newResult = await networkBlocker.blockBinary(binaryPath, timeout: newExpiresAt.timeIntervalSinceNow)
                if case .success(let newRule) = newResult {
                    try? db.saveNetworkRule(newRule, itemIdentifier: item.identifier)
                    state.networkRule = newRule
                    containmentStates[item.identifier] = state
                }
            }
        }

        // Log the extension
        let action = ContainmentAction(
            id: nil,
            itemIdentifier: item.identifier,
            itemCategory: item.category.rawValue,
            actionType: .extendTimeout,
            timestamp: Date(),
            binaryPath: item.effectiveExecutablePath?.path,
            binaryHash: state.binaryHash,
            plistPath: item.plistPath?.path,
            plistBackup: nil,
            networkRuleId: state.networkRule?.id,
            networkAnchor: state.networkRule?.anchor,
            networkMethod: state.networkRule?.method.rawValue,
            status: .active,
            expiresAt: newExpiresAt,
            details: nil
        )

        do {
            let savedAction = try db.saveContainmentAction(action)
            return .success(savedAction)
        } catch {
            return .failure(.databaseError(error.localizedDescription))
        }
    }

    /// Get containment state for an item
    func getContainmentState(for identifier: String) -> ContainmentState {
        return containmentStates[identifier] ?? .none
    }

    /// Get action history for an item
    func getActionHistory(for identifier: String) -> [ContainmentAction] {
        return (try? db.getContainmentHistory(for: identifier)) ?? []
    }

    /// Check if item is contained
    func isContained(_ identifier: String) -> Bool {
        return containedItems.contains(identifier)
    }

    /// Verify binary integrity (compare current hash with stored hash)
    func verifyBinaryIntegrity(_ item: PersistenceItem) -> (matches: Bool, currentHash: String?, storedHash: String?) {
        guard let binaryPath = item.effectiveExecutablePath,
              let state = containmentStates[item.identifier],
              let storedHash = state.binaryHash else {
            return (false, nil, nil)
        }

        let currentHash = networkBlocker.hashBinary(binaryPath)
        return (currentHash == storedHash, currentHash, storedHash)
    }

    // MARK: - Private Implementation

    /// Disable persistence by renaming plist to .contained
    private func disablePersistence(_ item: PersistenceItem) async -> Result<String?, ContainmentError> {
        guard let plistPath = item.plistPath else {
            return .failure(.plistNotFound)
        }

        // Read plist content for backup
        let plistBackup = try? String(contentsOf: plistPath, encoding: .utf8)

        let containedPath = plistPath.path + ".contained"

        // If loaded, unload first
        if item.isLoaded {
            let unloadResult = await unloadItem(item)
            if case .failure(let error) = unloadResult {
                print("[SafeContainment] Warning: Failed to unload item: \(error)")
            }
        }

        // Rename plist
        let fm = FileManager.default
        let needsAdmin = !fm.isWritableFile(atPath: plistPath.deletingLastPathComponent().path)

        if needsAdmin {
            let script = """
                do shell script "mv '\(plistPath.path)' '\(containedPath)'" with administrator privileges
                """
            let appleScript = NSAppleScript(source: script)
            var errorDict: NSDictionary?
            appleScript?.executeAndReturnError(&errorDict)

            if errorDict != nil {
                return .failure(.permissionDenied)
            }
        } else {
            do {
                try fm.moveItem(atPath: plistPath.path, toPath: containedPath)
            } catch {
                return .failure(.fileOperationFailed(error.localizedDescription))
            }
        }

        return .success(plistBackup)
    }

    /// Re-enable persistence by renaming .contained back to original
    private func enablePersistence(_ item: PersistenceItem, plistBackup: String?) async -> Result<Void, ContainmentError> {
        guard let plistPath = item.plistPath else {
            return .failure(.plistNotFound)
        }

        let containedPath = plistPath.path + ".contained"

        // Check if .contained file exists
        let fm = FileManager.default
        guard fm.fileExists(atPath: containedPath) else {
            // Try to restore from backup if we have it
            if let backup = plistBackup {
                do {
                    try backup.write(toFile: plistPath.path, atomically: true, encoding: .utf8)
                    return .success(())
                } catch {
                    return .failure(.fileOperationFailed("No .contained file and backup restore failed"))
                }
            }
            return .failure(.fileOperationFailed("No .contained file found"))
        }

        let needsAdmin = !fm.isWritableFile(atPath: plistPath.deletingLastPathComponent().path)

        if needsAdmin {
            let script = """
                do shell script "mv '\(containedPath)' '\(plistPath.path)'" with administrator privileges
                """
            let appleScript = NSAppleScript(source: script)
            var errorDict: NSDictionary?
            appleScript?.executeAndReturnError(&errorDict)

            if errorDict != nil {
                return .failure(.permissionDenied)
            }
        } else {
            do {
                try fm.moveItem(atPath: containedPath, toPath: plistPath.path)
            } catch {
                return .failure(.fileOperationFailed(error.localizedDescription))
            }
        }

        return .success(())
    }

    /// Unload a LaunchAgent/LaunchDaemon
    private func unloadItem(_ item: PersistenceItem) async -> Result<Void, ContainmentError> {
        guard let plistPath = item.plistPath else {
            return .failure(.plistNotFound)
        }

        let domain: String
        let target: String

        if item.category == .launchDaemons {
            domain = "system"
            target = plistPath.path
        } else {
            domain = "gui/\(getuid())"
            target = plistPath.path
        }

        let output = await CommandRunner.run(
            "/bin/launchctl",
            arguments: ["bootout", domain, target],
            timeout: 10.0
        )

        // bootout returns error even on success sometimes, so we don't check output
        return .success(())
    }

    /// Load active containments from database
    private func loadActiveContainments() async {
        do {
            let activeContainments = try db.getAllActiveContainments()

            for action in activeContainments {
                // Check if expired
                if let expiresAt = action.expiresAt, Date() > expiresAt {
                    try? db.updateContainmentStatus(id: action.id ?? 0, status: .expired)
                    continue
                }

                let networkRule = try? db.getNetworkRule(for: action.itemIdentifier)

                let state = ContainmentState(
                    isContained: true,
                    persistenceDisabled: action.actionType == .contain || action.actionType == .persistenceDisable,
                    networkBlocked: networkRule != nil,
                    networkRule: networkRule,
                    binaryHash: action.binaryHash,
                    containedAt: action.timestamp,
                    expiresAt: action.expiresAt
                )

                containmentStates[action.itemIdentifier] = state
                containedItems.insert(action.itemIdentifier)
            }

            print("[SafeContainment] Loaded \(containedItems.count) active containments")

        } catch {
            print("[SafeContainment] Error loading active containments: \(error)")
        }
    }

    /// Handle network rule expiration
    private func handleRuleExpired(_ rule: NetworkRule) {
        // Find the item identifier for this rule
        if let (_, identifier) = (try? db.getActiveNetworkRules())?.first(where: { $0.rule.id == rule.id }) {
            // Update state
            if var state = containmentStates[identifier] {
                state.networkBlocked = false
                state.networkRule = nil

                // If persistence is also not disabled, item is no longer contained
                if !state.persistenceDisabled {
                    state.isContained = false
                    containedItems.remove(identifier)
                }

                containmentStates[identifier] = state
            }

            // Remove rule from database
            try? db.removeNetworkRule(id: rule.id)

            // Update action status if no longer contained
            if let activeAction = try? db.getActiveContainment(for: identifier),
               let actionId = activeAction.id,
               containmentStates[identifier]?.isContained != true {
                try? db.updateContainmentStatus(id: actionId, status: .expired)
            }
        }
    }
}
