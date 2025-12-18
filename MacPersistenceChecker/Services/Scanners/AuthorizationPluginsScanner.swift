import Foundation

/// Scanner per Authorization Plugins - plugin caricati dal framework di autorizzazione
/// Path: /Library/Security/SecurityAgentPlugins/
final class AuthorizationPluginsScanner: PersistenceScanner {
    let category: PersistenceCategory = .authorizationPlugins
    let requiresFullDiskAccess: Bool = false

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/Security/SecurityAgentPlugins"),
            URL(fileURLWithPath: "/System/Library/Security/SecurityAgentPlugins")
        ]
    }

    // Known Apple authorization plugins
    private let knownApplePlugins: Set<String> = [
        "PKINITMechanism.bundle",
        "DiskUnlock.bundle",
        "FDERecoveryAgent.bundle",
        "KeychainSyncAccountUpdater.bundle",
        "loginKC.bundle"
    ]

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        for dirURL in monitoredPaths {
            guard FileManager.default.fileExists(atPath: dirURL.path) else {
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )

                for bundleURL in contents {
                    // Authorization plugins are bundles (.bundle)
                    guard bundleURL.pathExtension == "bundle" else {
                        continue
                    }

                    if let item = await scanPlugin(bundleURL, isSystemPath: dirURL.path.hasPrefix("/System")) {
                        items.append(item)
                    }
                }
            } catch {
                print("AuthorizationPluginsScanner: Failed to scan \(dirURL.path): \(error)")
            }
        }

        return items
    }

    // MARK: - Plugin Analysis

    private func scanPlugin(_ bundleURL: URL, isSystemPath: Bool) async -> PersistenceItem? {
        let bundleName = bundleURL.lastPathComponent

        // Try to load bundle info
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
            // Try to find any executable in MacOS directory
            let macOSDir = bundleURL.appendingPathComponent("Contents/MacOS")
            if let contents = try? FileManager.default.contentsOfDirectory(at: macOSDir, includingPropertiesForKeys: nil, options: []) {
                executablePath = contents.first
            }
        }

        var item = PersistenceItem(
            identifier: bundleIdentifier ?? bundleURL.path,
            category: .authorizationPlugins,
            name: bundleName,
            plistPath: infoPlistURL,
            executablePath: executablePath
        )

        item.bundleIdentifier = bundleIdentifier
        item.version = version
        item.isEnabled = true

        // Get timestamps
        if let attrs = try? FileManager.default.attributesOfItem(atPath: bundleURL.path) {
            item.plistModifiedAt = attrs[.modificationDate] as? Date
        }

        if let execPath = executablePath,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execPath.path) {
            item.binaryModifiedAt = attrs[.modificationDate] as? Date
        }

        // Determine trust level
        if isSystemPath {
            item.trustLevel = .apple
        } else if knownApplePlugins.contains(bundleName) {
            // Known Apple plugin in third-party location - suspicious
            item.trustLevel = .suspicious
        }

        return item
    }
}
