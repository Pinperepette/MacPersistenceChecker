import Foundation

/// Scanner per BTM Database - Background Task Management (macOS 13+)
/// Apple ha introdotto questo sistema per centralizzare il tracking della persistenza
/// Path: /private/var/db/com.apple.backgroundtaskmanagement/
final class BTMDatabaseScanner: PersistenceScanner {
    let category: PersistenceCategory = .btmDatabase
    let requiresFullDiskAccess: Bool = true

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/private/var/db/com.apple.backgroundtaskmanagement"),
            URL(fileURLWithPath: "/var/db/com.apple.backgroundtaskmanagement")
        ]
    }

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Check macOS version - BTM is only available on macOS 13+
        if #available(macOS 13.0, *) {
            // Use sfltool to dump BTM database
            let sfltoolItems = await scanViaSfltool()
            items.append(contentsOf: sfltoolItems)

            // Also try direct database access if we have FDA
            let directItems = await scanDatabaseDirectly()

            // Merge, avoiding duplicates
            for item in directItems {
                if !items.contains(where: { $0.identifier == item.identifier }) {
                    items.append(item)
                }
            }
        }

        return items
    }

    // MARK: - sfltool Query

    @available(macOS 13.0, *)
    private func scanViaSfltool() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // sfltool dumpbtm dumps the BTM database
        let output = await CommandRunner.run(
            "/usr/bin/sfltool",
            arguments: ["dumpbtm"],
            timeout: 10.0
        )

        if output.isEmpty {
            return items
        }

        items.append(contentsOf: parseSfltoolOutput(output))

        return items
    }

    private func parseSfltoolOutput(_ output: String) -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // sfltool dumpbtm output format varies but typically includes:
        // - Bundle identifier
        // - Executable path
        // - Item type (LaunchAgent, LoginItem, etc.)
        // - UUID
        // - Developer name

        var currentItem: [String: String] = [:]

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // End of item block
                if !currentItem.isEmpty {
                    if let item = createItemFromParsedData(currentItem) {
                        items.append(item)
                    }
                    currentItem = [:]
                }
                continue
            }

            // Parse key-value pairs
            if let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

                // Normalize keys
                if key.contains("identifier") || key.contains("bundle") {
                    currentItem["identifier"] = value
                } else if key.contains("path") || key.contains("executable") {
                    currentItem["path"] = value
                } else if key.contains("type") || key.contains("kind") {
                    currentItem["type"] = value
                } else if key.contains("name") || key.contains("label") {
                    currentItem["name"] = value
                } else if key.contains("developer") || key.contains("team") {
                    currentItem["developer"] = value
                } else if key.contains("uuid") {
                    currentItem["uuid"] = value
                } else if key.contains("enabled") || key.contains("active") {
                    currentItem["enabled"] = value
                }
            }
        }

        // Don't forget the last item
        if !currentItem.isEmpty {
            if let item = createItemFromParsedData(currentItem) {
                items.append(item)
            }
        }

        return items
    }

    private func createItemFromParsedData(_ data: [String: String]) -> PersistenceItem? {
        guard let identifier = data["identifier"] ?? data["name"] ?? data["uuid"] else {
            return nil
        }

        let displayName = data["name"] ?? identifier.components(separatedBy: ".").last ?? identifier

        var item = PersistenceItem(
            identifier: "btm-\(identifier)",
            category: .btmDatabase,
            name: displayName
        )

        if let path = data["path"] {
            item.executablePath = URL(fileURLWithPath: path)

            // Get timestamps
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                item.binaryModifiedAt = attrs[.modificationDate] as? Date
            }
        }

        item.bundleIdentifier = data["identifier"]

        if let type = data["type"] {
            item.programArguments = [type]
        }

        if let developer = data["developer"] {
            item.workingDirectory = developer // Store developer info
        }

        // Parse enabled state
        if let enabled = data["enabled"]?.lowercased() {
            item.isEnabled = enabled == "true" || enabled == "yes" || enabled == "1"
        } else {
            item.isEnabled = true
        }

        // Trust level based on identifier
        if identifier.hasPrefix("com.apple.") {
            item.trustLevel = .apple
        }

        return item
    }

    // MARK: - Direct Database Access

    private func scanDatabaseDirectly() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        for baseURL in monitoredPaths {
            guard FileManager.default.fileExists(atPath: baseURL.path) else {
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: baseURL,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: []
                )

                for fileURL in contents {
                    // BTM stores data in plist files
                    if fileURL.pathExtension == "plist" {
                        if let plistItems = parseBTMPlist(fileURL) {
                            items.append(contentsOf: plistItems)
                        }
                    }
                }
            } catch {
                // Permission denied is expected without FDA
            }
        }

        return items
    }

    private func parseBTMPlist(_ plistURL: URL) -> [PersistenceItem]? {
        guard let plistData = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) else {
            return nil
        }

        var items: [PersistenceItem] = []

        // BTM plist structure can vary
        if let dict = plist as? [String: Any] {
            // Try to extract items from various possible structures
            if let itemsArray = dict["items"] as? [[String: Any]] {
                for itemDict in itemsArray {
                    if let item = parseBTMItemDict(itemDict, source: plistURL.lastPathComponent) {
                        items.append(item)
                    }
                }
            } else {
                // Single item
                if let item = parseBTMItemDict(dict, source: plistURL.lastPathComponent) {
                    items.append(item)
                }
            }
        } else if let array = plist as? [[String: Any]] {
            for itemDict in array {
                if let item = parseBTMItemDict(itemDict, source: plistURL.lastPathComponent) {
                    items.append(item)
                }
            }
        }

        return items.isEmpty ? nil : items
    }

    private func parseBTMItemDict(_ dict: [String: Any], source: String) -> PersistenceItem? {
        let identifier = dict["bundleIdentifier"] as? String ??
                        dict["identifier"] as? String ??
                        dict["label"] as? String

        guard let id = identifier else {
            return nil
        }

        let name = dict["name"] as? String ?? id.components(separatedBy: ".").last ?? id

        var item = PersistenceItem(
            identifier: "btm-\(id)",
            category: .btmDatabase,
            name: name
        )

        item.bundleIdentifier = id

        if let path = dict["executablePath"] as? String ?? dict["path"] as? String {
            item.executablePath = URL(fileURLWithPath: path)
        }

        if let type = dict["type"] as? String {
            item.programArguments = [type]
        }

        item.isEnabled = dict["enabled"] as? Bool ?? true

        if id.hasPrefix("com.apple.") {
            item.trustLevel = .apple
        }

        return item
    }
}
