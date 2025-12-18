import Foundation

/// Scanner per Finder Sync Extensions - estensioni che si integrano con Finder
/// Es: Dropbox, iCloud, OneDrive, etc.
/// Query: pluginkit -m -i com.apple.FinderSync
final class FinderSyncExtensionsScanner: PersistenceScanner {
    let category: PersistenceCategory = .finderSyncExtensions
    let requiresFullDiskAccess: Bool = false

    var monitoredPaths: [URL] {
        [] // Extensions are queried via pluginkit
    }

    // Known legitimate Finder Sync extensions
    private let knownLegitimate: Set<String> = [
        "com.apple.CloudDocs.FinderSync",
        "com.apple.CloudDocs.MobileDocumentsFileProvider",
        "com.getdropbox.dropbox.garcon",
        "com.microsoft.OneDrive-mac.FinderSync",
        "com.google.drivefs.finderhelper.findersync",
        "com.boxsync.FinderExtension"
    ]

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Query Finder Sync extensions
        let finderSyncExtensions = await queryFinderSyncExtensions()
        items.append(contentsOf: finderSyncExtensions)

        // Also check for other relevant App Extension types
        let actionExtensions = await queryExtensions(protocol: "com.apple.services")
        items.append(contentsOf: actionExtensions)

        return items
    }

    // MARK: - Extension Queries

    private func queryFinderSyncExtensions() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Query Finder Sync extensions
        let output = await CommandRunner.run(
            "/usr/bin/pluginkit",
            arguments: ["-m", "-i", "com.apple.FinderSync"],
            timeout: 5.0
        )

        items.append(contentsOf: parsePluginkitOutput(output, extensionType: "FinderSync"))

        return items
    }

    private func queryExtensions(protocol extensionProtocol: String) async -> [PersistenceItem] {
        let output = await CommandRunner.run(
            "/usr/bin/pluginkit",
            arguments: ["-m", "-p", extensionProtocol],
            timeout: 5.0
        )

        return parsePluginkitOutput(output, extensionType: extensionProtocol)
    }

    // MARK: - Output Parsing

    private func parsePluginkitOutput(_ output: String, extensionType: String) -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        guard !output.isEmpty else {
            return items
        }

        // pluginkit output format varies, but typically includes:
        // + identifier(version) path
        // or
        // identifier version path

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let extensionInfo = parseExtensionLine(trimmed) {
                var item = PersistenceItem(
                    identifier: extensionInfo.identifier,
                    category: .finderSyncExtensions,
                    name: extensionInfo.displayName
                )

                if let path = extensionInfo.path {
                    let pathURL = URL(fileURLWithPath: path)

                    // Determine if this is an appex bundle
                    if path.hasSuffix(".appex") {
                        item.plistPath = pathURL.appendingPathComponent("Contents/Info.plist")

                        // Find executable
                        let infoPlistURL = item.plistPath!
                        if let plistData = try? Data(contentsOf: infoPlistURL),
                           let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
                           let execName = plist["CFBundleExecutable"] as? String {
                            item.executablePath = pathURL.appendingPathComponent("Contents/MacOS/\(execName)")
                        }
                    } else {
                        item.executablePath = pathURL
                    }

                    // Get timestamps
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                        item.plistModifiedAt = attrs[.modificationDate] as? Date
                    }
                }

                item.version = extensionInfo.version
                item.bundleIdentifier = extensionInfo.identifier
                item.isEnabled = extensionInfo.isEnabled
                item.programArguments = [extensionType]

                // Determine trust level
                if extensionInfo.identifier.hasPrefix("com.apple.") {
                    item.trustLevel = .apple
                } else if knownLegitimate.contains(extensionInfo.identifier) {
                    item.trustLevel = .knownVendor
                }

                items.append(item)
            }
        }

        return items
    }

    private struct ExtensionInfo {
        let identifier: String
        let displayName: String
        let version: String?
        let path: String?
        let isEnabled: Bool
    }

    private func parseExtensionLine(_ line: String) -> ExtensionInfo? {
        // Handle different pluginkit output formats

        // Format 1: +    com.example.extension(1.0)    /path/to/extension.appex
        // Format 2: -    com.example.extension(1.0)    /path/to/extension.appex
        // Format 3: com.example.extension    1.0    /path/to/extension.appex

        var isEnabled = true
        var workingLine = line

        // Check for enabled/disabled prefix
        if workingLine.hasPrefix("+") {
            isEnabled = true
            workingLine = String(workingLine.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if workingLine.hasPrefix("-") {
            isEnabled = false
            workingLine = String(workingLine.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Try to extract identifier
        var identifier: String?
        var version: String?
        var path: String?

        // Pattern: identifier(version) path
        if let parenRange = workingLine.range(of: "(") {
            identifier = String(workingLine[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)

            if let closeParenRange = workingLine.range(of: ")") {
                version = String(workingLine[parenRange.upperBound..<closeParenRange.lowerBound])

                let remaining = String(workingLine[closeParenRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                if remaining.hasPrefix("/") {
                    path = remaining
                }
            }
        } else {
            // Try space-separated format
            let components = workingLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if components.count >= 1 {
                identifier = String(components[0])
            }
            if components.count >= 2 {
                let secondPart = String(components[1])
                // Check if it's a version or path
                if secondPart.hasPrefix("/") {
                    path = secondPart
                } else {
                    version = secondPart
                }
            }
            if components.count >= 3 {
                path = String(components[2])
            }
        }

        guard let id = identifier, !id.isEmpty else {
            return nil
        }

        // Create display name from identifier
        let displayName = id.components(separatedBy: ".").last ?? id

        return ExtensionInfo(
            identifier: id,
            displayName: displayName,
            version: version,
            path: path,
            isEnabled: isEnabled
        )
    }
}
