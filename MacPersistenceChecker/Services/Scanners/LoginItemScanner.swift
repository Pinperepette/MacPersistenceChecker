import Foundation
import ServiceManagement

/// Scanner per Login Items
final class LoginItemScanner: PersistenceScanner {
    let category: PersistenceCategory = .loginItems
    let requiresFullDiskAccess: Bool = false

    var monitoredPaths: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/com.apple.backgroundtaskmanagementagent")
        ]
    }

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Scan using launchctl for background items
        items.append(contentsOf: await scanBackgroundItems())

        // Scan legacy login items plist
        items.append(contentsOf: await scanLegacyLoginItems())

        return items
    }

    /// Scan background items using launchctl print
    private func scanBackgroundItems() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Use launchctl to get background items
        let output = await runCommand(
            "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())"]
        )

        // Parse the output to find login items
        // This is a simplified approach - full parsing would be more complex
        let lines = output.components(separatedBy: "\n")
        var inServicesSection = false

        for line in lines {
            if line.contains("services = {") {
                inServicesSection = true
                continue
            }
            if inServicesSection && line.contains("}") {
                break
            }

            if inServicesSection {
                // Parse service entry
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\"") || trimmed.hasPrefix("0x") {
                    // This is a service identifier
                    if let identifier = extractServiceIdentifier(from: trimmed) {
                        // Filter for likely login items
                        if isLikelyLoginItem(identifier) {
                            let item = PersistenceItem(
                                identifier: identifier,
                                category: .loginItems,
                                name: cleanupName(identifier),
                                isEnabled: true,
                                isLoaded: true
                            )
                            items.append(item)
                        }
                    }
                }
            }
        }

        return items
    }

    /// Scan legacy login items from plist
    private func scanLegacyLoginItems() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        let legacyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.loginitems.plist")

        guard FileManager.default.fileExists(atPath: legacyPath.path),
              let data = try? Data(contentsOf: legacyPath),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return items
        }

        // Parse legacy format
        if let sessionItems = plist["SessionItems"] as? [String: Any],
           let customListItems = sessionItems["CustomListItems"] as? [[String: Any]] {

            for entry in customListItems {
                guard let name = entry["Name"] as? String else { continue }

                var item = PersistenceItem(
                    identifier: name,
                    category: .loginItems,
                    name: name
                )

                // Try to get the alias/path
                if let aliasData = entry["Alias"] as? Data {
                    // Resolve bookmark/alias data
                    if let resolvedURL = resolveAlias(aliasData) {
                        item.executablePath = resolvedURL
                    }
                }

                item.isEnabled = !(entry["Hidden"] as? Bool ?? false)
                items.append(item)
            }
        }

        return items
    }

    // MARK: - Helpers

    private func runCommand(_ path: String, arguments: [String]) async -> String {
        await CommandRunner.run(path, arguments: arguments, timeout: 5.0)
    }

    private func extractServiceIdentifier(from line: String) -> String? {
        // Extract identifier from launchctl output
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Format: "identifier" = { ... } or 0xaddr "identifier"
        // Find content between first pair of quotes
        guard let firstQuote = trimmed.firstIndex(of: "\"") else {
            return nil
        }
        let afterFirstQuote = trimmed.index(after: firstQuote)
        guard afterFirstQuote < trimmed.endIndex,
              let secondQuote = trimmed[afterFirstQuote...].firstIndex(of: "\"") else {
            return nil
        }
        return String(trimmed[afterFirstQuote..<secondQuote])
    }

    private func isLikelyLoginItem(_ identifier: String) -> Bool {
        // Filter out system services
        let systemPrefixes = [
            "com.apple.",
            "system/",
            "com.apple.xpc"
        ]

        for prefix in systemPrefixes {
            if identifier.hasPrefix(prefix) {
                return false
            }
        }

        return true
    }

    private func cleanupName(_ identifier: String) -> String {
        // Convert bundle ID to readable name
        var name = identifier

        // Remove common prefixes
        let prefixes = ["application.", "gui/", "user/"]
        for prefix in prefixes {
            if name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
        }

        // Get last component of bundle ID
        if let lastComponent = name.split(separator: ".").last {
            name = String(lastComponent)
        }

        return name
    }

    private func resolveAlias(_ aliasData: Data) -> URL? {
        var stale = false
        do {
            let resolvedURL = try URL(
                resolvingBookmarkData: aliasData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return resolvedURL
        } catch {
            return nil
        }
    }
}
