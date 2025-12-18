import Foundation

/// Scanner per Privileged Helper Tools
final class PrivilegedHelperScanner: PersistenceScanner {
    let category: PersistenceCategory = .privilegedHelpers
    let requiresFullDiskAccess: Bool = false

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/PrivilegedHelperTools")
        ]
    }

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        for basePath in monitoredPaths {
            guard FileManager.default.fileExists(atPath: basePath.path) else {
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: basePath,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isExecutableKey],
                    options: []
                )

                for helperURL in contents {
                    // Skip non-executable files
                    let resourceValues = try? helperURL.resourceValues(forKeys: [.isExecutableKey])
                    if resourceValues?.isExecutable != true {
                        continue
                    }

                    // Skip directories (we want binaries)
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: helperURL.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        continue
                    }

                    let item = await parseHelper(at: helperURL)
                    items.append(item)
                }
            } catch {
                print("Failed to scan \(basePath.path): \(error)")
            }
        }

        // Also check for corresponding launchd plists
        items = await enrichWithLaunchdInfo(items)

        return items
    }

    private func parseHelper(at url: URL) async -> PersistenceItem {
        let name = url.lastPathComponent

        var item = PersistenceItem(
            identifier: name,
            category: .privilegedHelpers,
            name: name,
            executablePath: url
        )

        // Get file timestamps
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            item.binaryModifiedAt = attrs[.modificationDate] as? Date
        }

        // Try to find the parent application
        item.parentAppPath = await findParentApp(for: name)

        // Try to extract bundle info from the binary
        if let bundleInfo = extractEmbeddedInfo(from: url) {
            item.bundleIdentifier = bundleInfo.bundleId
            item.version = bundleInfo.version
        }

        item.isEnabled = true
        item.isLoaded = true // Helpers are typically always available

        return item
    }

    private func enrichWithLaunchdInfo(_ items: [PersistenceItem]) async -> [PersistenceItem] {
        var enrichedItems = items

        // Look for corresponding launchd plists in /Library/LaunchDaemons
        let launchdPath = URL(fileURLWithPath: "/Library/LaunchDaemons")

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: launchdPath,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return enrichedItems
        }

        for (index, item) in enrichedItems.enumerated() {
            // Look for plist that references this helper
            for plistURL in contents where plistURL.pathExtension == "plist" {
                if let data = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {

                    // Check if this plist references our helper
                    if let program = plist["Program"] as? String,
                       program.contains(item.identifier) {
                        enrichedItems[index].plistPath = plistURL

                        if let label = plist["Label"] as? String {
                            enrichedItems[index].identifier = label
                        }

                        enrichedItems[index].runAtLoad = plist["RunAtLoad"] as? Bool
                        enrichedItems[index].keepAlive = plist["KeepAlive"] as? Bool

                        break
                    }

                    if let args = plist["ProgramArguments"] as? [String],
                       args.contains(where: { $0.contains(item.identifier) }) {
                        enrichedItems[index].plistPath = plistURL

                        if let label = plist["Label"] as? String {
                            enrichedItems[index].identifier = label
                        }

                        enrichedItems[index].programArguments = args
                        enrichedItems[index].runAtLoad = plist["RunAtLoad"] as? Bool

                        break
                    }
                }
            }
        }

        return enrichedItems
    }

    private func findParentApp(for helperName: String) async -> URL? {
        // Common pattern: helper name matches app bundle ID prefix
        // e.g., com.company.app.helper -> /Applications/App.app

        // Search in common app locations
        let searchPaths = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]

        for searchPath in searchPaths {
            guard let apps = try? FileManager.default.contentsOfDirectory(
                at: searchPath,
                includingPropertiesForKeys: nil,
                options: []
            ) else {
                continue
            }

            for appURL in apps where appURL.pathExtension == "app" {
                // Check app's embedded helpers
                let helpersPath = appURL
                    .appendingPathComponent("Contents/Library/LaunchServices")

                if let helpers = try? FileManager.default.contentsOfDirectory(atPath: helpersPath.path) {
                    if helpers.contains(helperName) {
                        return appURL
                    }
                }

                // Check app's bundle ID
                let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
                if let data = try? Data(contentsOf: infoPlist),
                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                   let appBundleId = plist["CFBundleIdentifier"] as? String {

                    // Check if helper name starts with app bundle ID
                    if helperName.hasPrefix(appBundleId) {
                        return appURL
                    }
                }
            }
        }

        return nil
    }

    private func extractEmbeddedInfo(from binaryURL: URL) -> (bundleId: String?, version: String?)? {
        // Try to read embedded plist from binary (common for helpers)
        // This is a simplified approach - real implementation would use otool or similar

        guard let data = try? Data(contentsOf: binaryURL) else {
            return nil
        }

        // Look for embedded plist markers
        let plistMarker = "<?xml version"
        guard let dataString = String(data: data, encoding: .utf8),
              let startRange = dataString.range(of: plistMarker),
              let endRange = dataString.range(of: "</plist>", range: startRange.lowerBound..<dataString.endIndex) else {
            return nil
        }

        let plistString = String(dataString[startRange.lowerBound...endRange.upperBound])

        guard let plistData = plistString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        return (
            plist["CFBundleIdentifier"] as? String,
            plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String
        )
    }
}
