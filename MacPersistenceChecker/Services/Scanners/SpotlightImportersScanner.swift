import Foundation

/// Scanner per Spotlight Importers - plugin usati da Spotlight per indicizzare file
/// Paths: /Library/Spotlight/, ~/Library/Spotlight/
final class SpotlightImportersScanner: PersistenceScanner {
    let category: PersistenceCategory = .spotlightImporters
    let requiresFullDiskAccess: Bool = false

    private let home = FileManager.default.homeDirectoryForCurrentUser

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/Spotlight"),
            home.appendingPathComponent("Library/Spotlight"),
            URL(fileURLWithPath: "/System/Library/Spotlight")
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
                    // Spotlight importers are .mdimporter bundles
                    guard bundleURL.pathExtension == "mdimporter" else {
                        continue
                    }

                    if let item = await scanImporter(bundleURL, isSystemPath: isSystemPath) {
                        items.append(item)
                    }
                }
            } catch {
                print("SpotlightImportersScanner: Failed to scan \(dirURL.path): \(error)")
            }
        }

        // Also get registered importers via mdimport command
        let registeredImporters = await scanRegisteredImporters()

        // Merge with filesystem scan, avoiding duplicates
        for importer in registeredImporters {
            if !items.contains(where: { $0.identifier == importer.identifier }) {
                items.append(importer)
            }
        }

        return items
    }

    // MARK: - Bundle Scanning

    private func scanImporter(_ bundleURL: URL, isSystemPath: Bool) async -> PersistenceItem? {
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

            // Get supported UTIs
            if let utis = plist["CFBundleDocumentTypes"] as? [[String: Any]] {
                for uti in utis {
                    if let types = uti["LSItemContentTypes"] as? [String] {
                        supportedTypes.append(contentsOf: types)
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
            category: .spotlightImporters,
            name: bundleName.replacingOccurrences(of: ".mdimporter", with: ""),
            plistPath: infoPlistURL,
            executablePath: executablePath
        )

        item.bundleIdentifier = bundleIdentifier
        item.version = version
        item.isEnabled = true

        // Store supported types
        if !supportedTypes.isEmpty {
            item.programArguments = Array(supportedTypes.prefix(5)) // Limit for display
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

    // MARK: - Registered Importers

    private func scanRegisteredImporters() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Use mdimport to list all registered importers
        let output = await CommandRunner.run(
            "/usr/bin/mdimport",
            arguments: ["-L"],
            timeout: 5.0
        )

        if output.isEmpty {
            return items
        }

        // Parse output - format varies but typically lists paths
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Extract path from the output
            // Format is typically: "path/to/importer.mdimporter"
            if trimmed.hasSuffix(".mdimporter") || trimmed.contains(".mdimporter") {
                // Try to extract the path
                if let path = extractImporterPath(from: trimmed) {
                    let url = URL(fileURLWithPath: path)
                    let isSystem = path.hasPrefix("/System/")

                    if let item = await scanImporter(url, isSystemPath: isSystem) {
                        items.append(item)
                    }
                }
            }
        }

        return items
    }

    private func extractImporterPath(from line: String) -> String? {
        // Try to find a path that ends with .mdimporter
        let pattern = #"(/[^\s"]+\.mdimporter)"#

        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, options: [], range: range),
               let matchRange = Range(match.range(at: 1), in: line) {
                return String(line[matchRange])
            }
        }

        // Fallback: if line looks like a path
        if line.hasPrefix("/") && line.contains(".mdimporter") {
            return line.components(separatedBy: ".mdimporter").first.map { $0 + ".mdimporter" }
        }

        return nil
    }
}
