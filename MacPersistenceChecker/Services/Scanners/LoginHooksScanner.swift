import Foundation

/// Scanner per Login/Logout Hooks - meccanismo legacy ma ancora funzionante
/// Verifica: defaults read com.apple.loginwindow LoginHook/LogoutHook
final class LoginHooksScanner: PersistenceScanner {
    let category: PersistenceCategory = .loginHooks
    let requiresFullDiskAccess: Bool = false

    var monitoredPaths: [URL] {
        [] // Hooks are read from defaults, not from paths
    }

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Check LoginHook
        if let loginHook = await readLoginHook() {
            items.append(loginHook)
        }

        // Check LogoutHook
        if let logoutHook = await readLogoutHook() {
            items.append(logoutHook)
        }

        // Also check user-level hooks
        if let userLoginHook = await readUserLoginHook() {
            items.append(userLoginHook)
        }

        if let userLogoutHook = await readUserLogoutHook() {
            items.append(userLogoutHook)
        }

        return items
    }

    // MARK: - System-level Hooks

    private func readLoginHook() async -> PersistenceItem? {
        let output = await CommandRunner.run(
            "/usr/bin/defaults",
            arguments: ["read", "com.apple.loginwindow", "LoginHook"],
            timeout: 3.0
        )

        return parseHookOutput(output, hookType: "LoginHook", isSystem: true)
    }

    private func readLogoutHook() async -> PersistenceItem? {
        let output = await CommandRunner.run(
            "/usr/bin/defaults",
            arguments: ["read", "com.apple.loginwindow", "LogoutHook"],
            timeout: 3.0
        )

        return parseHookOutput(output, hookType: "LogoutHook", isSystem: true)
    }

    // MARK: - User-level Hooks

    private func readUserLoginHook() async -> PersistenceItem? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plistPath = "\(home)/Library/Preferences/com.apple.loginwindow.plist"

        guard FileManager.default.fileExists(atPath: plistPath) else {
            return nil
        }

        let output = await CommandRunner.run(
            "/usr/bin/defaults",
            arguments: ["read", plistPath, "LoginHook"],
            timeout: 3.0
        )

        return parseHookOutput(output, hookType: "User LoginHook", isSystem: false)
    }

    private func readUserLogoutHook() async -> PersistenceItem? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let plistPath = "\(home)/Library/Preferences/com.apple.loginwindow.plist"

        guard FileManager.default.fileExists(atPath: plistPath) else {
            return nil
        }

        let output = await CommandRunner.run(
            "/usr/bin/defaults",
            arguments: ["read", plistPath, "LogoutHook"],
            timeout: 3.0
        )

        return parseHookOutput(output, hookType: "User LogoutHook", isSystem: false)
    }

    // MARK: - Parsing

    private func parseHookOutput(_ output: String, hookType: String, isSystem: Bool) -> PersistenceItem? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if hook exists (defaults returns error message if not set)
        if trimmed.isEmpty ||
           trimmed.contains("does not exist") ||
           trimmed.contains("Domain") {
            return nil
        }

        // The output should be the path to the hook script
        let hookPath = trimmed

        var item = PersistenceItem(
            identifier: "\(hookType)-\(isSystem ? "system" : "user")",
            category: .loginHooks,
            name: hookType
        )

        item.executablePath = URL(fileURLWithPath: hookPath)
        item.isEnabled = true
        item.workingDirectory = isSystem ? "/Library/Preferences" : "~/Library/Preferences"

        // Check if the hook script exists and get its info
        if FileManager.default.fileExists(atPath: hookPath) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: hookPath) {
                item.binaryModifiedAt = attrs[.modificationDate] as? Date
            }

            // Read first line to check for shebang
            if let content = try? String(contentsOfFile: hookPath, encoding: .utf8) {
                let firstLine = content.components(separatedBy: .newlines).first ?? ""
                item.programArguments = [firstLine]
            }
        } else {
            // Hook is configured but script doesn't exist - suspicious
            item.trustLevel = .suspicious
            item.programArguments = ["Script not found: \(hookPath)"]
        }

        return item
    }
}
