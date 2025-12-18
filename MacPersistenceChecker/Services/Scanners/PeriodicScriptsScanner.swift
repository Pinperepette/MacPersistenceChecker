import Foundation

/// Scanner per Periodic Scripts - script eseguiti periodicamente da launchd
/// Paths: /etc/periodic/daily/, /etc/periodic/weekly/, /etc/periodic/monthly/
final class PeriodicScriptsScanner: PersistenceScanner {
    let category: PersistenceCategory = .periodicScripts
    let requiresFullDiskAccess: Bool = false

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/etc/periodic/daily"),
            URL(fileURLWithPath: "/etc/periodic/weekly"),
            URL(fileURLWithPath: "/etc/periodic/monthly"),
            URL(fileURLWithPath: "/usr/local/etc/periodic/daily"),
            URL(fileURLWithPath: "/usr/local/etc/periodic/weekly"),
            URL(fileURLWithPath: "/usr/local/etc/periodic/monthly")
        ]
    }

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        for dirURL in monitoredPaths {
            guard FileManager.default.fileExists(atPath: dirURL.path) else {
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isExecutableKey],
                    options: [.skipsHiddenFiles]
                )

                for fileURL in contents {
                    // Skip non-files
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                          !isDirectory.boolValue else {
                        continue
                    }

                    let schedule = extractSchedule(from: dirURL.path)
                    let isSystemScript = isAppleScript(fileURL)

                    var item = PersistenceItem(
                        identifier: fileURL.path,
                        category: .periodicScripts,
                        name: fileURL.lastPathComponent,
                        executablePath: fileURL
                    )

                    item.programArguments = [schedule]
                    item.workingDirectory = dirURL.path
                    item.isEnabled = true

                    // Get timestamps
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                        item.binaryModifiedAt = attrs[.modificationDate] as? Date
                    }

                    // Pre-set trust level hint for Apple scripts
                    if isSystemScript {
                        item.trustLevel = .apple
                    }

                    items.append(item)
                }
            } catch {
                // Permission denied is common, continue with other directories
                print("PeriodicScriptsScanner: Failed to scan \(dirURL.path): \(error)")
            }
        }

        return items
    }

    // MARK: - Helpers

    private func extractSchedule(from path: String) -> String {
        if path.contains("daily") {
            return "@daily"
        } else if path.contains("weekly") {
            return "@weekly"
        } else if path.contains("monthly") {
            return "@monthly"
        }
        return "periodic"
    }

    private func isAppleScript(_ url: URL) -> Bool {
        // Apple's periodic scripts are typically numbered (100.clean-logs, 500.daily, etc.)
        let name = url.lastPathComponent
        let path = url.path

        // System path check
        if path.hasPrefix("/etc/periodic/") && !path.hasPrefix("/usr/local/") {
            // Most scripts in /etc/periodic are Apple's
            // They typically have numeric prefixes
            if let firstChar = name.first, firstChar.isNumber {
                return true
            }
        }

        return false
    }
}
