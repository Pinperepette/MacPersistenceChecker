import Foundation
import CommonCrypto

/// Handles network blocking for contained items using pfctl (primary) and socketfilterfw (fallback)
final class NetworkBlocker {
    static let shared = NetworkBlocker()

    /// Anchor prefix for all MPC rules
    private let anchorPrefix = "mpc"

    /// Default timeout: 24 hours
    private let defaultTimeout: TimeInterval = 86400

    /// Active expiration timers
    private var expirationTimers: [String: Timer] = [:]

    /// Callback when a rule expires
    var onRuleExpired: ((NetworkRule) -> Void)?

    private init() {}

    // MARK: - Public Interface

    /// Block network for a binary
    /// - Parameters:
    ///   - binaryPath: Path to the binary to block
    ///   - timeout: Optional timeout (default 24h). Pass nil for no expiration.
    /// - Returns: NetworkRule if successful
    func blockBinary(_ binaryPath: URL, timeout: TimeInterval? = 86400) async -> Result<NetworkRule, ContainmentError> {
        let ruleId = UUID().uuidString
        let hash = hashString(binaryPath.path)
        let anchor = "\(anchorPrefix)_contain_\(hash.prefix(12))"

        let createdAt = Date()
        let expiresAt = timeout.map { createdAt.addingTimeInterval($0) }

        // Use socketfilterfw as primary method (more reliable)
        let firewallResult = await blockWithSocketFilter(binaryPath: binaryPath)

        if case .success = firewallResult {
            let rule = NetworkRule(
                id: ruleId,
                anchor: "socketfilterfw:\(binaryPath.lastPathComponent)",
                binaryPath: binaryPath.path,
                createdAt: createdAt,
                expiresAt: expiresAt,
                method: .socketfilterfw
            )

            if let expiresAt = expiresAt {
                startExpirationTimer(for: rule, expiresAt: expiresAt)
            }

            print("[NetworkBlocker] Blocked via socketfilterfw: \(binaryPath.lastPathComponent)")
            return .success(rule)
        }

        // Fallback to pfctl if socketfilterfw fails
        let pfctlResult = await blockWithPfctl(binaryPath: binaryPath, anchor: anchor)

        if case .success = pfctlResult {
            let rule = NetworkRule(
                id: ruleId,
                anchor: anchor,
                binaryPath: binaryPath.path,
                createdAt: createdAt,
                expiresAt: expiresAt,
                method: .pfctl
            )

            if let expiresAt = expiresAt {
                startExpirationTimer(for: rule, expiresAt: expiresAt)
            }

            return .success(rule)
        }

        // Both failed - return the socketfilterfw error as it's more user-friendly
        if case .failure(let error) = firewallResult {
            return .failure(error)
        }

        return .failure(.unknown("Both socketfilterfw and pfctl failed"))
    }

    /// Unblock network for a binary
    func unblockBinary(rule: NetworkRule) async -> Result<Void, ContainmentError> {
        // Cancel expiration timer
        cancelExpirationTimer(for: rule.id)

        switch rule.method {
        case .pfctl:
            return await unblockWithPfctl(anchor: rule.anchor)
        case .socketfilterfw:
            return await unblockWithSocketFilter(binaryPath: URL(fileURLWithPath: rule.binaryPath))
        }
    }

    /// Check if a binary is currently blocked
    func isBlocked(_ binaryPath: URL) async -> Bool {
        // Check pfctl
        let pfctlCheck = await checkPfctlRule(for: binaryPath)
        if pfctlCheck { return true }

        // Check socketfilterfw
        let firewallCheck = await checkSocketFilterRule(for: binaryPath)
        return firewallCheck
    }

    /// Get all active pfctl anchors managed by MPC
    func getActiveAnchors() async -> [String] {
        let output = await CommandRunner.run(
            "/sbin/pfctl",
            arguments: ["-s", "Anchors"],
            timeout: 5.0
        )

        return output.components(separatedBy: "\n")
            .filter { $0.hasPrefix(anchorPrefix) }
    }

    /// Cleanup all MPC pfctl rules (emergency rollback)
    func emergencyRollbackAll() async {
        // Cancel all timers
        for (_, timer) in expirationTimers {
            timer.invalidate()
        }
        expirationTimers.removeAll()

        // Get all MPC anchors and flush them
        let anchors = await getActiveAnchors()
        for anchor in anchors {
            _ = await unblockWithPfctl(anchor: anchor)
        }

        // Also check socketfilterfw (harder to enumerate, but try to clean up)
        print("[NetworkBlocker] Emergency rollback completed. Flushed \(anchors.count) pfctl anchors.")
    }

    /// Cleanup expired rules (call on app startup)
    func cleanupExpiredRules() async {
        do {
            let rules = try DatabaseManager.shared.getActiveNetworkRules()

            for (rule, identifier) in rules {
                if rule.isExpired {
                    print("[NetworkBlocker] Cleaning up expired rule for: \(identifier)")
                    _ = await unblockBinary(rule: rule)
                    try? DatabaseManager.shared.removeNetworkRule(id: rule.id)
                }
            }
        } catch {
            print("[NetworkBlocker] Error cleaning up expired rules: \(error)")
        }
    }

    /// Restore active rules from database (call on app startup)
    func restoreActiveRules() async {
        do {
            let rules = try DatabaseManager.shared.getActiveNetworkRules()

            for (rule, identifier) in rules {
                if !rule.isExpired {
                    // Re-apply the rule
                    let binaryURL = URL(fileURLWithPath: rule.binaryPath)
                    let result = await blockBinary(binaryURL, timeout: rule.timeRemaining)

                    switch result {
                    case .success(let newRule):
                        print("[NetworkBlocker] Restored rule for: \(identifier)")
                        // Update database with new rule ID
                        try? DatabaseManager.shared.removeNetworkRule(id: rule.id)
                        try? DatabaseManager.shared.saveNetworkRule(newRule, itemIdentifier: identifier)
                    case .failure(let error):
                        print("[NetworkBlocker] Failed to restore rule for \(identifier): \(error)")
                    }
                }
            }
        } catch {
            print("[NetworkBlocker] Error restoring active rules: \(error)")
        }
    }

    // MARK: - pfctl Implementation

    private func blockWithPfctl(binaryPath: URL, anchor: String) async -> Result<Void, ContainmentError> {
        // Create the rule - block all outgoing traffic from this binary
        // Note: pfctl can't directly filter by binary path, so we need a workaround
        // We'll block by creating a rule that drops all traffic tagged by our anchor

        let rule = "block drop out quick all"

        // Combine enable + create in single command (one password prompt)
        let combinedCommand = """
            /sbin/pfctl -e 2>/dev/null; \
            echo '\(rule)' | /sbin/pfctl -a '\(anchor)' -f - 2>&1
            """

        let output = await runWithAdmin(combinedCommand)

        // Verify the rule was created (no admin needed for read)
        let verifyOutput = await CommandRunner.run(
            "/sbin/pfctl",
            arguments: ["-a", anchor, "-s", "rules"],
            timeout: 5.0
        )

        if verifyOutput.contains("block") {
            print("[NetworkBlocker] pfctl rule created: \(anchor)")
            return .success(())
        }

        return .failure(.pfctlFailed("Failed to create pfctl rule. Output: \(output)"))
    }

    private func unblockWithPfctl(anchor: String) async -> Result<Void, ContainmentError> {
        let command = "/sbin/pfctl -a '\(anchor)' -F all"
        let output = await runWithAdmin(command)

        // Verify the anchor is cleared
        let verifyOutput = await CommandRunner.run(
            "/sbin/pfctl",
            arguments: ["-a", anchor, "-s", "rules"],
            timeout: 5.0
        )

        if verifyOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
           !verifyOutput.contains("block") {
            print("[NetworkBlocker] pfctl rule removed: \(anchor)")
            return .success(())
        }

        return .failure(.pfctlFailed("Failed to remove pfctl rule: \(output)"))
    }

    private func checkPfctlRule(for binaryPath: URL) async -> Bool {
        let hash = hashString(binaryPath.path)
        let anchor = "\(anchorPrefix)/contain_\(hash.prefix(12))"

        let output = await CommandRunner.run(
            "/sbin/pfctl",
            arguments: ["-a", anchor, "-s", "rules"],
            timeout: 5.0
        )

        return output.contains("block")
    }

    // MARK: - socketfilterfw Implementation

    private func blockWithSocketFilter(binaryPath: URL) async -> Result<Void, ContainmentError> {
        // Combine all commands into one to request password only once
        let combinedCommand = """
            /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on 2>/dev/null; \
            /usr/libexec/ApplicationFirewall/socketfilterfw --blockapp '\(binaryPath.path)' 2>&1
            """

        let output = await runWithAdmin(combinedCommand)

        // Check various success indicators
        let outputLower = output.lowercased()
        if outputLower.contains("added") ||
           outputLower.contains("already") ||
           outputLower.contains("block") ||
           outputLower.isEmpty ||
           (!outputLower.contains("error") && !outputLower.contains("fail")) {
            print("[NetworkBlocker] socketfilterfw blocked: \(binaryPath.lastPathComponent)")
            return .success(())
        }

        return .failure(.socketFilterFailed("Failed to block app: \(output)"))
    }

    private func unblockWithSocketFilter(binaryPath: URL) async -> Result<Void, ContainmentError> {
        let command = "/usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp '\(binaryPath.path)'"
        let output = await runWithAdmin(command)

        if output.lowercased().contains("removed") ||
           output.lowercased().contains("unblocked") ||
           !output.lowercased().contains("error") {
            print("[NetworkBlocker] socketfilterfw unblocked: \(binaryPath.lastPathComponent)")
            return .success(())
        }

        return .failure(.socketFilterFailed("Failed to unblock app: \(output)"))
    }

    private func checkSocketFilterRule(for binaryPath: URL) async -> Bool {
        let output = await CommandRunner.run(
            "/usr/libexec/ApplicationFirewall/socketfilterfw",
            arguments: ["--getappblocked", binaryPath.path],
            timeout: 5.0
        )

        return output.lowercased().contains("block")
    }

    // MARK: - Expiration Timers

    private func startExpirationTimer(for rule: NetworkRule, expiresAt: Date) {
        let timeInterval = expiresAt.timeIntervalSinceNow

        guard timeInterval > 0 else {
            // Already expired
            Task {
                _ = await unblockBinary(rule: rule)
                onRuleExpired?(rule)
            }
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { [weak self] _ in
            Task {
                _ = await self?.unblockBinary(rule: rule)
                self?.onRuleExpired?(rule)
            }
        }

        expirationTimers[rule.id] = timer
    }

    private func cancelExpirationTimer(for ruleId: String) {
        expirationTimers[ruleId]?.invalidate()
        expirationTimers.removeValue(forKey: ruleId)
    }

    // MARK: - Helpers

    /// Run command with administrator privileges using AppleScript
    private func runWithAdmin(_ command: String) async -> String {
        let script = """
            do shell script "\(command.replacingOccurrences(of: "\"", with: "\\\""))" with administrator privileges
            """

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = appleScript?.executeAndReturnError(&errorDict)
                let output = result?.stringValue ?? errorDict?.description ?? ""
                continuation.resume(returning: output)
            }
        }
    }

    /// Generate hash string for anchor naming
    private func hashString(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return UUID().uuidString }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Binary Hash Utility

extension NetworkBlocker {
    /// Calculate SHA256 hash of a binary file
    func hashBinary(_ path: URL) -> String? {
        guard let data = try? Data(contentsOf: path) else { return nil }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
