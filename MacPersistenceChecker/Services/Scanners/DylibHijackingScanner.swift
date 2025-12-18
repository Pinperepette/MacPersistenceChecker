import Foundation

/// Scanner per Dylib Hijacking - variabili d'ambiente e path per iniezione dylib
/// Controlla: DYLD_INSERT_LIBRARIES, DYLD_LIBRARY_PATH, etc.
final class DylibHijackingScanner: PersistenceScanner {
    let category: PersistenceCategory = .dylibHijacking
    let requiresFullDiskAccess: Bool = false

    var monitoredPaths: [URL] {
        [] // Environment-based, not path-based
    }

    // Dangerous DYLD environment variables
    private let dangerousDyldVars: [String] = [
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FALLBACK_FRAMEWORK_PATH",
        "DYLD_IMAGE_SUFFIX",
        "DYLD_FORCE_FLAT_NAMESPACE",
        "DYLD_PRINT_LIBRARIES"
    ]

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Check current environment
        items.append(contentsOf: scanCurrentEnvironment())

        // Check launchd environment
        items.append(contentsOf: await scanLaunchdEnvironment())

        // Check environment.plist (legacy)
        items.append(contentsOf: scanEnvironmentPlist())

        // Check for suspicious dylibs in common hijack locations
        items.append(contentsOf: await scanCommonHijackLocations())

        return items
    }

    // MARK: - Current Environment

    private func scanCurrentEnvironment() -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        for varName in dangerousDyldVars {
            if let value = ProcessInfo.processInfo.environment[varName] {
                var item = PersistenceItem(
                    identifier: "env-\(varName)",
                    category: .dylibHijacking,
                    name: varName
                )

                item.programArguments = [value]
                item.isEnabled = true
                item.trustLevel = .suspicious
                item.workingDirectory = "Current Environment"

                // Try to extract dylib path
                if varName == "DYLD_INSERT_LIBRARIES" {
                    let dylibPaths = value.components(separatedBy: ":")
                    if let firstDylib = dylibPaths.first {
                        item.executablePath = URL(fileURLWithPath: firstDylib)

                        if let attrs = try? FileManager.default.attributesOfItem(atPath: firstDylib) {
                            item.binaryModifiedAt = attrs[.modificationDate] as? Date
                        }
                    }
                }

                items.append(item)
            }
        }

        return items
    }

    // MARK: - Launchd Environment

    private func scanLaunchdEnvironment() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Get launchd environment using launchctl
        let output = await CommandRunner.run(
            "/bin/launchctl",
            arguments: ["getenv", "DYLD_INSERT_LIBRARIES"],
            timeout: 3.0
        )

        if !output.isEmpty && !output.contains("Could not find") {
            var item = PersistenceItem(
                identifier: "launchd-DYLD_INSERT_LIBRARIES",
                category: .dylibHijacking,
                name: "DYLD_INSERT_LIBRARIES (launchd)"
            )

            let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
            item.programArguments = [value]
            item.isEnabled = true
            item.trustLevel = .suspicious
            item.workingDirectory = "launchd environment"

            let dylibPaths = value.components(separatedBy: ":")
            if let firstDylib = dylibPaths.first {
                item.executablePath = URL(fileURLWithPath: firstDylib)
            }

            items.append(item)
        }

        // Also check other DYLD vars in launchd
        for varName in dangerousDyldVars where varName != "DYLD_INSERT_LIBRARIES" {
            let varOutput = await CommandRunner.run(
                "/bin/launchctl",
                arguments: ["getenv", varName],
                timeout: 3.0
            )

            if !varOutput.isEmpty && !varOutput.contains("Could not find") {
                var item = PersistenceItem(
                    identifier: "launchd-\(varName)",
                    category: .dylibHijacking,
                    name: "\(varName) (launchd)"
                )

                item.programArguments = [varOutput.trimmingCharacters(in: .whitespacesAndNewlines)]
                item.isEnabled = true
                item.trustLevel = .suspicious
                item.workingDirectory = "launchd environment"

                items.append(item)
            }
        }

        return items
    }

    // MARK: - Environment.plist (Legacy)

    private func scanEnvironmentPlist() -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        let home = FileManager.default.homeDirectoryForCurrentUser
        let envPlistPath = home.appendingPathComponent(".MacOSX/environment.plist")

        guard FileManager.default.fileExists(atPath: envPlistPath.path) else {
            return items
        }

        guard let plistData = try? Data(contentsOf: envPlistPath),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return items
        }

        for varName in dangerousDyldVars {
            if let value = plist[varName] as? String {
                var item = PersistenceItem(
                    identifier: "envplist-\(varName)",
                    category: .dylibHijacking,
                    name: "\(varName) (environment.plist)"
                )

                item.plistPath = envPlistPath
                item.programArguments = [value]
                item.isEnabled = true
                item.trustLevel = .suspicious
                item.workingDirectory = "~/.MacOSX/environment.plist"

                if let attrs = try? FileManager.default.attributesOfItem(atPath: envPlistPath.path) {
                    item.plistModifiedAt = attrs[.modificationDate] as? Date
                }

                items.append(item)
            }
        }

        return items
    }

    // MARK: - Common Hijack Locations

    private func scanCommonHijackLocations() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Common locations where hijack dylibs might be placed
        let hijackLocations = [
            "/usr/local/lib",
            "/opt/local/lib",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("lib").path
        ]

        for location in hijackLocations {
            guard FileManager.default.fileExists(atPath: location) else {
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: location)

                for file in contents {
                    // Look for suspicious dylib names that might indicate hijacking
                    if isSuspiciousDylib(file) {
                        let fullPath = (location as NSString).appendingPathComponent(file)

                        var item = PersistenceItem(
                            identifier: "dylib-\(fullPath)",
                            category: .dylibHijacking,
                            name: file,
                            executablePath: URL(fileURLWithPath: fullPath)
                        )

                        item.isEnabled = true
                        item.trustLevel = .suspicious
                        item.workingDirectory = location
                        item.programArguments = ["Suspicious dylib location"]

                        if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) {
                            item.binaryModifiedAt = attrs[.modificationDate] as? Date
                        }

                        items.append(item)
                    }
                }
            } catch {
                // Permission denied
            }
        }

        return items
    }

    private func isSuspiciousDylib(_ filename: String) -> Bool {
        let lowercased = filename.lowercased()

        // Suspicious patterns
        let suspiciousPatterns = [
            // System library names in wrong locations
            "libsystem",
            "libobjc",
            "libdispatch",
            "security.framework",
            "corefoundation",
            // Common hijack names
            "inject",
            "hook",
            "patch",
            "payload",
            "exploit",
            // Hidden files
            ".dylib"
        ]

        // Check for suspicious patterns
        for pattern in suspiciousPatterns {
            if lowercased.contains(pattern) {
                return true
            }
        }

        // Check for dylibs with unusual characteristics
        if lowercased.hasSuffix(".dylib") {
            // Very short names might be suspicious
            if filename.count <= 5 {
                return true
            }

            // Random-looking names
            if containsRandomSequence(filename) {
                return true
            }
        }

        return false
    }

    private func containsRandomSequence(_ name: String) -> Bool {
        // Check if the filename contains what looks like a random hex sequence
        let hexPattern = #"[0-9a-f]{8,}"#

        if let regex = try? NSRegularExpression(pattern: hexPattern, options: .caseInsensitive) {
            let range = NSRange(name.startIndex..., in: name)
            return regex.firstMatch(in: name, options: [], range: range) != nil
        }

        return false
    }
}
