import Foundation

/// Scanner per Kernel Extensions
final class KextScanner: PersistenceScanner {
    let category: PersistenceCategory = .kernelExtensions
    let requiresFullDiskAccess: Bool = true

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/Extensions"),
            URL(fileURLWithPath: "/System/Library/Extensions")
        ]
    }

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Get list of loaded kexts for reference
        let loadedKexts = await getLoadedKexts()

        // Scan filesystem for .kext bundles
        for basePath in monitoredPaths {
            guard FileManager.default.fileExists(atPath: basePath.path) else {
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: basePath,
                    includingPropertiesForKeys: nil,
                    options: []
                )

                for kextURL in contents where kextURL.pathExtension == "kext" {
                    if let item = try? parseKext(at: kextURL, loadedKexts: loadedKexts) {
                        items.append(item)
                    }
                }
            } catch {
                print("Failed to scan \(basePath.path): \(error)")
            }
        }

        return items
    }

    private func parseKext(at url: URL, loadedKexts: Set<String>) throws -> PersistenceItem {
        let infoPlist = url.appendingPathComponent("Contents/Info.plist")

        guard FileManager.default.fileExists(atPath: infoPlist.path) else {
            // Try alternative location
            let altInfoPlist = url.appendingPathComponent("Info.plist")
            if FileManager.default.fileExists(atPath: altInfoPlist.path) {
                return try parseKextInfo(at: altInfoPlist, kextURL: url, loadedKexts: loadedKexts)
            }
            throw ScannerError.invalidPlist("No Info.plist found in \(url.path)")
        }

        return try parseKextInfo(at: infoPlist, kextURL: url, loadedKexts: loadedKexts)
    }

    private func parseKextInfo(
        at infoPlist: URL,
        kextURL: URL,
        loadedKexts: Set<String>
    ) throws -> PersistenceItem {
        let data = try Data(contentsOf: infoPlist)

        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw ScannerError.invalidPlist(infoPlist.path)
        }

        let bundleId = plist["CFBundleIdentifier"] as? String ?? kextURL.lastPathComponent
        let name = plist["CFBundleName"] as? String ??
                   plist["CFBundleExecutable"] as? String ??
                   kextURL.deletingPathExtension().lastPathComponent

        var item = PersistenceItem(
            identifier: bundleId,
            category: .kernelExtensions,
            name: name,
            plistPath: infoPlist
        )

        // Set executable path
        if let executable = plist["CFBundleExecutable"] as? String {
            item.executablePath = kextURL
                .appendingPathComponent("Contents/MacOS")
                .appendingPathComponent(executable)

            // Try alternative location if standard doesn't exist
            if !FileManager.default.fileExists(atPath: item.executablePath!.path) {
                item.executablePath = kextURL.appendingPathComponent(executable)
            }
        }

        item.bundleIdentifier = bundleId
        item.version = plist["CFBundleShortVersionString"] as? String ??
                       plist["CFBundleVersion"] as? String

        // Check if loaded
        item.isLoaded = loadedKexts.contains(bundleId)
        item.isEnabled = true

        // Get timestamps
        if let attrs = try? FileManager.default.attributesOfItem(atPath: infoPlist.path) {
            item.plistModifiedAt = attrs[.modificationDate] as? Date
        }

        if let execPath = item.executablePath?.path,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execPath) {
            item.binaryModifiedAt = attrs[.modificationDate] as? Date
        }

        return item
    }

    private func getLoadedKexts() async -> Set<String> {
        let output = await CommandRunner.run("/usr/sbin/kextstat", arguments: ["-l"], timeout: 5.0)

        var loadedKexts = Set<String>()

        // Parse kextstat output
        // Format: Index Refs Address Size Wired Name (Version) UUID <Linked Against>
        for line in output.components(separatedBy: "\n") {
            let components = line.split(whereSeparator: { $0.isWhitespace })
            // Bundle ID is typically the 6th component (index 5)
            if components.count >= 6 {
                let bundleId = String(components[5])
                // Remove version in parentheses if present
                if let parenIndex = bundleId.firstIndex(of: "(") {
                    loadedKexts.insert(String(bundleId[..<parenIndex]))
                } else {
                    loadedKexts.insert(bundleId)
                }
            }
        }

        return loadedKexts
    }
}
