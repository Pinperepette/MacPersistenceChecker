import Foundation

/// Scanner per Directory Services Plugins - plugin per servizi directory (LDAP, AD, etc.)
/// Path: /Library/DirectoryServices/PlugIns/
final class DirectoryServicesPluginsScanner: PersistenceScanner {
    let category: PersistenceCategory = .directoryServicesPlugins
    let requiresFullDiskAccess: Bool = true

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/DirectoryServices/PlugIns"),
            URL(fileURLWithPath: "/System/Library/Frameworks/DirectoryService.framework/Resources/Plugins")
        ]
    }

    // Known Apple Directory Services plugins
    private let knownApplePlugins: Set<String> = [
        "AppleTalk.dsplug",
        "BSD.dsplug",
        "Configure.dsplug",
        "LDAPv3.dsplug",
        "Local.dsplug",
        "NIS.dsplug",
        "Search.dsplug"
    ]

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
                    // DS plugins can be .dsplug or .bundle
                    let ext = bundleURL.pathExtension
                    guard ext == "dsplug" || ext == "bundle" else {
                        continue
                    }

                    if let item = await scanPlugin(bundleURL, isSystemPath: isSystemPath) {
                        items.append(item)
                    }
                }
            } catch {
                print("DirectoryServicesPluginsScanner: Failed to scan \(dirURL.path): \(error)")
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

        if let plistData = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
            bundleIdentifier = plist["CFBundleIdentifier"] as? String
            executableName = plist["CFBundleExecutable"] as? String
            version = plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String
        }

        // Find executable
        var executablePath: URL?
        if let execName = executableName {
            executablePath = bundleURL.appendingPathComponent("Contents/MacOS/\(execName)")
        } else {
            // Try to find any executable
            let macOSDir = bundleURL.appendingPathComponent("Contents/MacOS")
            if let contents = try? FileManager.default.contentsOfDirectory(at: macOSDir, includingPropertiesForKeys: nil, options: []) {
                executablePath = contents.first
            }
        }

        // Clean up display name
        let displayName = bundleName
            .replacingOccurrences(of: ".dsplug", with: "")
            .replacingOccurrences(of: ".bundle", with: "")

        var item = PersistenceItem(
            identifier: bundleIdentifier ?? bundleURL.path,
            category: .directoryServicesPlugins,
            name: displayName,
            plistPath: infoPlistURL,
            executablePath: executablePath
        )

        item.bundleIdentifier = bundleIdentifier
        item.version = version
        item.isEnabled = true

        // Timestamps
        if let attrs = try? FileManager.default.attributesOfItem(atPath: bundleURL.path) {
            item.plistModifiedAt = attrs[.modificationDate] as? Date
        }

        if let execPath = executablePath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execPath.path) {
            item.binaryModifiedAt = attrs[.modificationDate] as? Date
        }

        // Trust level
        if isSystemPath {
            item.trustLevel = .apple
        } else if knownApplePlugins.contains(bundleName) {
            // Known Apple plugin in non-system location
            item.trustLevel = .suspicious
        } else if bundleIdentifier?.hasPrefix("com.apple.") ?? false {
            item.trustLevel = .apple
        }

        return item
    }
}
