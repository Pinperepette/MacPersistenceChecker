import Foundation

/// Scanner per Quick Look Plugins - plugin usati per anteprima file
/// Paths: /Library/QuickLook/, ~/Library/QuickLook/
final class QuickLookPluginsScanner: PersistenceScanner {
    let category: PersistenceCategory = .quickLookPlugins
    let requiresFullDiskAccess: Bool = false

    private let home = FileManager.default.homeDirectoryForCurrentUser

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/QuickLook"),
            home.appendingPathComponent("Library/QuickLook"),
            URL(fileURLWithPath: "/System/Library/QuickLook")
        ]
    }

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        for dirURL in monitoredPaths {
            guard FileManager.default.fileExists(atPath: dirURL.path) else {
                continue
            }

            let isSystemPath = dirURL.path.hasPrefix("/System/")

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                for bundleURL in contents {
                    // Quick Look plugins are .qlgenerator bundles
                    guard bundleURL.pathExtension == "qlgenerator" else {
                        continue
                    }

                    if let item = await scanPlugin(bundleURL, isSystemPath: isSystemPath) {
                        items.append(item)
                    }
                }
            } catch {
                print("QuickLookPluginsScanner: Failed to scan \(dirURL.path): \(error)")
            }
        }

        // Also query qlmanage for registered generators
        let registered = await scanRegisteredGenerators()
        for gen in registered {
            if !items.contains(where: { $0.identifier == gen.identifier }) {
                items.append(gen)
            }
        }

        return items
    }

    // MARK: - Plugin Scanning

    private func scanPlugin(_ bundleURL: URL, isSystemPath: Bool) async -> PersistenceItem? {
        let bundleName = bundleURL.lastPathComponent

        // Load Info.plist
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        var bundleIdentifier: String?
        var executableName: String?
        var version: String?
        var supportedTypes: [String] = []

        if let plistData = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
            bundleIdentifier = plist["CFBundleIdentifier"] as? String
            executableName = plist["CFBundleExecutable"] as? String
            version = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String

            // Get supported content types
            if let types = plist["CFBundleDocumentTypes"] as? [[String: Any]] {
                for type in types {
                    if let contentTypes = type["LSItemContentTypes"] as? [String] {
                        supportedTypes.append(contentsOf: contentTypes)
                    }
                }
            }
        }

        // Find executable
        var executablePath: URL?
        if let execName = executableName {
            executablePath = bundleURL.appendingPathComponent("Contents/MacOS/\(execName)")
        }

        var item = PersistenceItem(
            identifier: bundleIdentifier ?? bundleURL.path,
            category: .quickLookPlugins,
            name: bundleName.replacingOccurrences(of: ".qlgenerator", with: ""),
            plistPath: infoPlistURL,
            executablePath: executablePath
        )

        item.bundleIdentifier = bundleIdentifier
        item.version = version
        item.isEnabled = true

        // Store supported types
        if !supportedTypes.isEmpty {
            item.programArguments = Array(supportedTypes.prefix(5))
        }

        // Timestamps
        if let attrs = try? FileManager.default.attributesOfItem(atPath: bundleURL.path) {
            item.plistModifiedAt = attrs[.modificationDate] as? Date
        }

        if let execPath = executablePath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execPath.path) {
            item.binaryModifiedAt = attrs[.modificationDate] as? Date
        }

        // Trust level
        if isSystemPath || (bundleIdentifier?.hasPrefix("com.apple.") ?? false) {
            item.trustLevel = .apple
        }

        return item
    }

    // MARK: - Registered Generators

    private func scanRegisteredGenerators() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Use qlmanage to list generators
        let output = await CommandRunner.run(
            "/usr/bin/qlmanage",
            arguments: ["-m", "plugins"],
            timeout: 5.0
        )

        if output.isEmpty {
            return items
        }

        // Parse output
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.contains(".qlgenerator") else { continue }

            if let path = extractPluginPath(from: trimmed) {
                let url = URL(fileURLWithPath: path)
                let isSystem = path.hasPrefix("/System/")

                if let item = await scanPlugin(url, isSystemPath: isSystem) {
                    items.append(item)
                }
            }
        }

        return items
    }

    private func extractPluginPath(from line: String) -> String? {
        let pattern = #"(/[^\s"]+\.qlgenerator)"#

        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, options: [], range: range),
               let matchRange = Range(match.range(at: 1), in: line) {
                return String(line[matchRange])
            }
        }

        return nil
    }
}
