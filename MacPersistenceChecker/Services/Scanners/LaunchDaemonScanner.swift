import Foundation

/// Scanner per LaunchDaemons (servizi a livello di sistema)
final class LaunchDaemonScanner: PersistenceScanner {
    let category: PersistenceCategory = .launchDaemons
    let requiresFullDiskAccess: Bool = true

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/LaunchDaemons"),
            URL(fileURLWithPath: "/System/Library/LaunchDaemons")
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
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                )

                for fileURL in contents {
                    // Check for .plist files (enabled)
                    if fileURL.pathExtension == "plist" {
                        if let item = try? await parseLaunchPlist(at: fileURL, isDisabled: false) {
                            items.append(item)
                        }
                    }
                    // Check for .plist.disabled files (disabled by us)
                    else if fileURL.path.hasSuffix(".plist.disabled") {
                        if let item = try? await parseLaunchPlist(at: fileURL, isDisabled: true) {
                            items.append(item)
                        }
                    }
                }
            } catch {
                // Log but continue
                print("Failed to scan \(basePath.path): \(error)")
            }
        }

        return items
    }

    private func parseLaunchPlist(at url: URL, isDisabled: Bool) async throws -> PersistenceItem {
        let data = try Data(contentsOf: url)

        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw ScannerError.invalidPlist(url.path)
        }

        guard let label = plist["Label"] as? String else {
            throw ScannerError.invalidPlist("Missing Label in \(url.path)")
        }

        // For disabled items, store the original path (without .disabled)
        let originalPath: URL
        if isDisabled {
            let path = url.path.replacingOccurrences(of: ".disabled", with: "")
            originalPath = URL(fileURLWithPath: path)
        } else {
            originalPath = url
        }

        var item = PersistenceItem(
            identifier: label,
            category: .launchDaemons,
            name: isDisabled ? "\(label) [DISABLED]" : label,
            plistPath: originalPath,
            isEnabled: !isDisabled
        )

        // Extract executable path
        if let program = plist["Program"] as? String {
            item.executablePath = URL(fileURLWithPath: program)
        } else if let args = plist["ProgramArguments"] as? [String], let first = args.first {
            item.executablePath = URL(fileURLWithPath: first)
            item.programArguments = args
        }

        // Extract other properties
        item.runAtLoad = plist["RunAtLoad"] as? Bool
        item.keepAlive = plist["KeepAlive"] as? Bool
        item.workingDirectory = plist["WorkingDirectory"] as? String
        item.standardOutPath = plist["StandardOutPath"] as? String
        item.standardErrorPath = plist["StandardErrorPath"] as? String

        // Extract launch frequency properties (for anomaly detection)
        item.startInterval = plist["StartInterval"] as? Int
        item.throttleInterval = plist["ThrottleInterval"] as? Int
        if let calendar = plist["StartCalendarInterval"] as? [[String: Int]] {
            item.startCalendarInterval = calendar
        } else if let singleCalendar = plist["StartCalendarInterval"] as? [String: Int] {
            item.startCalendarInterval = [singleCalendar]
        }

        if let env = plist["EnvironmentVariables"] as? [String: String] {
            item.environmentVariables = env
        }

        // Check if loaded (disabled items are never loaded)
        item.isLoaded = isDisabled ? false : await checkIfLoaded(label: label)

        // Get file modification date
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            item.plistModifiedAt = attrs[.modificationDate] as? Date
        }

        // Get binary modification date
        if let binaryPath = item.executablePath?.path,
           let attrs = try? FileManager.default.attributesOfItem(atPath: binaryPath) {
            item.binaryModifiedAt = attrs[.modificationDate] as? Date
        }

        return item
    }

    private func checkIfLoaded(label: String) async -> Bool {
        let output = await CommandRunner.run("/bin/launchctl", arguments: ["list", label], timeout: 2.0)
        return !output.isEmpty
    }
}
