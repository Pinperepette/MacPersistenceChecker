import Foundation

/// Scanner per Application Support (items sospetti in path non standard)
final class ApplicationSupportScanner: PersistenceScanner {
    let category: PersistenceCategory = .applicationSupport
    let requiresFullDiskAccess: Bool = false

    var monitoredPaths: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        ]
    }

    // Patterns that indicate suspicious items
    private let suspiciousPatterns = [
        "helper",
        "daemon",
        "agent",
        "updater",
        "launcher",
        "loader",
        "injector",
        "hook",
        "monitor"
    ]

    // Known safe directories to skip
    private let safeDirs = [
        "Apple",
        "com.apple.",
        "AddressBook",
        "Dock",
        "Finder",
        "Microsoft",
        "Google",
        "Adobe",
        "Slack",
        "Discord",
        "Zoom",
        "Spotify",
        "Steam"
    ]

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        for basePath in monitoredPaths {
            guard FileManager.default.fileExists(atPath: basePath.path) else {
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: basePath,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )

                for dirURL in contents {
                    // Check if it's a directory
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir),
                          isDir.boolValue else {
                        continue
                    }

                    // Skip known safe directories
                    if shouldSkip(directory: dirURL.lastPathComponent) {
                        continue
                    }

                    // Scan directory for suspicious items
                    let suspiciousItems = try await scanDirectory(dirURL)
                    items.append(contentsOf: suspiciousItems)
                }
            } catch {
                print("Failed to scan \(basePath.path): \(error)")
            }
        }

        return items
    }

    private func shouldSkip(directory: String) -> Bool {
        let dirLower = directory.lowercased()

        for safe in safeDirs {
            if dirLower.hasPrefix(safe.lowercased()) || dirLower == safe.lowercased() {
                return true
            }
        }

        return false
    }

    private func scanDirectory(_ dirURL: URL) async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        let fileManager = FileManager.default

        // Recursively scan for executables
        guard let enumerator = fileManager.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true } // Continue on errors
        ) else {
            return items
        }

        for case let fileURL as URL in enumerator {
            // Skip if we've gone too deep (max 3 levels)
            let depth = fileURL.pathComponents.count - dirURL.pathComponents.count
            if depth > 3 {
                continue
            }

            // Check if it's a regular file
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            // Check if it's executable or looks suspicious
            let fileName = fileURL.lastPathComponent.lowercased()
            let isSuspicious = isSuspiciousFile(fileName: fileName, url: fileURL)

            if isSuspicious || resourceValues.isExecutable == true {
                var item = PersistenceItem(
                    identifier: fileURL.path,
                    category: .applicationSupport,
                    name: "\(dirURL.lastPathComponent)/\(fileURL.lastPathComponent)",
                    executablePath: fileURL
                )

                // Get file timestamps
                if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path) {
                    item.binaryModifiedAt = attrs[.modificationDate] as? Date
                }

                // Determine parent app
                item.parentAppPath = URL(fileURLWithPath: dirURL.path)

                item.isEnabled = true

                // Mark as suspicious by default (will be updated by trust verifier)
                item.trustLevel = .suspicious

                items.append(item)
            }
        }

        // Also check for .plist files that might be config for persistence
        let plistItems = try await scanForPlists(in: dirURL)
        items.append(contentsOf: plistItems)

        return items
    }

    private func isSuspiciousFile(fileName: String, url: URL) -> Bool {
        // Check against suspicious patterns
        for pattern in suspiciousPatterns {
            if fileName.contains(pattern) {
                return true
            }
        }

        // Check for scripts
        let suspiciousExtensions = ["sh", "py", "pl", "rb", "command", "tool"]
        if let ext = url.pathExtension.lowercased() as String?,
           suspiciousExtensions.contains(ext) {
            return true
        }

        // Check for executables without extension (common for malware)
        if url.pathExtension.isEmpty {
            // Check if file is executable
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return true
            }
        }

        // Check for suspiciously named files
        let suspiciousNames = [
            ".hidden",
            "~",
            "tmp",
            "temp",
            ".lock"
        ]

        for name in suspiciousNames {
            if fileName.contains(name) {
                return true
            }
        }

        return false
    }

    private func scanForPlists(in dirURL: URL) async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return items
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "plist" else { continue }

            // Skip if too deep
            let depth = fileURL.pathComponents.count - dirURL.pathComponents.count
            if depth > 3 { continue }

            // Try to parse the plist
            guard let data = try? Data(contentsOf: fileURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                continue
            }

            // Check if plist references executables (potential persistence config)
            if containsExecutableReference(plist) {
                var item = PersistenceItem(
                    identifier: fileURL.path,
                    category: .applicationSupport,
                    name: "\(dirURL.lastPathComponent)/\(fileURL.lastPathComponent)",
                    plistPath: fileURL
                )

                // Try to extract executable path from plist
                if let program = plist["Program"] as? String {
                    item.executablePath = URL(fileURLWithPath: program)
                } else if let args = plist["ProgramArguments"] as? [String], let first = args.first {
                    item.executablePath = URL(fileURLWithPath: first)
                    item.programArguments = args
                }

                item.runAtLoad = plist["RunAtLoad"] as? Bool
                item.keepAlive = plist["KeepAlive"] as? Bool

                // Get timestamps
                if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path) {
                    item.plistModifiedAt = attrs[.modificationDate] as? Date
                }

                item.isEnabled = true
                item.trustLevel = .suspicious

                items.append(item)
            }
        }

        return items
    }

    private func containsExecutableReference(_ plist: [String: Any]) -> Bool {
        // Check for common keys that indicate executable references
        let executableKeys = [
            "Program",
            "ProgramArguments",
            "CFBundleExecutable",
            "RunAtLoad",
            "KeepAlive",
            "LaunchOnlyOnce",
            "StartOnMount"
        ]

        for key in executableKeys {
            if plist[key] != nil {
                return true
            }
        }

        return false
    }
}
