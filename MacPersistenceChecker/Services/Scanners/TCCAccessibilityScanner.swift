import Foundation

/// Scanner per TCC/Accessibility - app con permessi di accessibilità e TCC
/// Le app con questi permessi possono monitorare input, controllare altre app, etc.
final class TCCAccessibilityScanner: PersistenceScanner {
    let category: PersistenceCategory = .tccAccessibility
    let requiresFullDiskAccess: Bool = true

    private let home = FileManager.default.homeDirectoryForCurrentUser

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        ]
    }

    // TCC service types we're interested in (security-relevant)
    private let relevantServices: Set<String> = [
        "kTCCServiceAccessibility",
        "kTCCServiceScreenCapture",
        "kTCCServiceSystemPolicyAllFiles",
        "kTCCServiceAppleEvents",
        "kTCCServiceListenEvent",
        "kTCCServicePostEvent",
        "kTCCServiceSystemPolicySysAdminFiles"
    ]

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Try to query TCC database via sqlite
        items.append(contentsOf: await queryTCCDatabase())

        // Also use tccutil if available for Accessibility
        items.append(contentsOf: await queryAccessibilityApps())

        // Check for apps registered with Accessibility via AXIsProcessTrustedWithOptions
        items.append(contentsOf: await checkAccessibilityTrust())

        return items
    }

    // MARK: - TCC Database Query

    private func queryTCCDatabase() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // System TCC database
        let systemTCCPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        if FileManager.default.fileExists(atPath: systemTCCPath) {
            items.append(contentsOf: await queryDatabase(at: systemTCCPath, isSystem: true))
        }

        // User TCC database
        let userTCCPath = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path
        if FileManager.default.fileExists(atPath: userTCCPath) {
            items.append(contentsOf: await queryDatabase(at: userTCCPath, isSystem: false))
        }

        return items
    }

    private func queryDatabase(at path: String, isSystem: Bool) async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Query access table for authorized entries
        let query = """
        SELECT client, service, auth_value, auth_reason, indirect_object_identifier
        FROM access
        WHERE auth_value = 2;
        """

        let output = await CommandRunner.run(
            "/usr/bin/sqlite3",
            arguments: ["-separator", "|", path, query],
            timeout: 5.0
        )

        if output.isEmpty || output.contains("Error") {
            return items
        }

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let components = trimmed.components(separatedBy: "|")
            guard components.count >= 3 else { continue }

            let client = components[0]
            let service = components[1]
            let authValue = components[2]

            // Only process if it's an allowed entry (auth_value = 2)
            guard authValue == "2" else { continue }

            // Filter to relevant services
            if !relevantServices.contains(service) && !service.contains("Accessibility") {
                continue
            }

            let serviceName = formatServiceName(service)

            var item = PersistenceItem(
                identifier: "tcc-\(client)-\(service)",
                category: .tccAccessibility,
                name: formatClientName(client)
            )

            item.bundleIdentifier = client
            item.programArguments = [serviceName]
            item.isEnabled = true
            item.workingDirectory = isSystem ? "System TCC" : "User TCC"

            // Try to find the app path
            if let appPath = findAppPath(for: client) {
                item.executablePath = URL(fileURLWithPath: appPath)

                if let attrs = try? FileManager.default.attributesOfItem(atPath: appPath) {
                    item.binaryModifiedAt = attrs[.modificationDate] as? Date
                }
            }

            // Trust level
            if client.hasPrefix("com.apple.") {
                item.trustLevel = .apple
            } else if isKnownLegitimate(client) {
                item.trustLevel = .knownVendor
            }

            items.append(item)
        }

        return items
    }

    // MARK: - Accessibility Apps Query

    private func queryAccessibilityApps() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Try using sqlite on the system TCC.db
        let output = await CommandRunner.run(
            "/usr/bin/sqlite3",
            arguments: [
                "/Library/Application Support/com.apple.TCC/TCC.db",
                "SELECT client FROM access WHERE service='kTCCServiceAccessibility' AND auth_value=2;"
            ],
            timeout: 5.0
        )

        if !output.isEmpty && !output.contains("Error") {
            for line in output.components(separatedBy: .newlines) {
                let client = line.trimmingCharacters(in: .whitespaces)
                guard !client.isEmpty else { continue }

                // Check if we already have this entry
                let identifier = "accessibility-\(client)"

                var item = PersistenceItem(
                    identifier: identifier,
                    category: .tccAccessibility,
                    name: formatClientName(client)
                )

                item.bundleIdentifier = client
                item.programArguments = ["Accessibility"]
                item.isEnabled = true

                if let appPath = findAppPath(for: client) {
                    item.executablePath = URL(fileURLWithPath: appPath)
                }

                if client.hasPrefix("com.apple.") {
                    item.trustLevel = .apple
                }

                items.append(item)
            }
        }

        return items
    }

    // MARK: - Accessibility Trust Check

    private func checkAccessibilityTrust() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Use AppleScript to list automation permissions
        let script = """
        tell application "System Events"
            get name of every process whose background only is false
        end tell
        """

        // This is limited without proper entitlements, but we can try
        // The actual accessibility status would need to be checked differently

        return items
    }

    // MARK: - Helpers

    private func formatServiceName(_ service: String) -> String {
        let mapping: [String: String] = [
            "kTCCServiceAccessibility": "Accessibility",
            "kTCCServiceScreenCapture": "Screen Recording",
            "kTCCServiceSystemPolicyAllFiles": "Full Disk Access",
            "kTCCServiceAppleEvents": "Automation",
            "kTCCServiceListenEvent": "Input Monitoring",
            "kTCCServicePostEvent": "Input Control",
            "kTCCServiceSystemPolicySysAdminFiles": "Admin File Access"
        ]

        return mapping[service] ?? service.replacingOccurrences(of: "kTCCService", with: "")
    }

    private func formatClientName(_ client: String) -> String {
        // Try to get just the app name from bundle identifier
        if client.contains(".") {
            return client.components(separatedBy: ".").last ?? client
        }

        // Try to extract from path
        if client.hasPrefix("/") {
            return URL(fileURLWithPath: client).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
        }

        return client
    }

    private func findAppPath(for bundleId: String) -> String? {
        // Try to find the app using mdfind
        let output = ProcessInfo.processInfo.environment["PATH"] != nil ?
            findAppViaMdfind(bundleId) : nil

        if let path = output {
            return path
        }

        // Common locations
        let commonPaths = [
            "/Applications/\(formatClientName(bundleId)).app",
            "/Applications/\(formatClientName(bundleId)).app/Contents/MacOS/\(formatClientName(bundleId))",
            home.appendingPathComponent("Applications/\(formatClientName(bundleId)).app").path
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    private func findAppViaMdfind(_ bundleId: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemCFBundleIdentifier == '\(bundleId)'"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            let paths = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
            return paths.first
        } catch {
            return nil
        }
    }

    private func isKnownLegitimate(_ bundleId: String) -> Bool {
        let knownLegitimate: Set<String> = [
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.lastpass.LastPass",
            "com.bitwarden.desktop",
            "com.microsoft.teams",
            "us.zoom.xos",
            "com.logmein.gotowebinar",
            "com.webex.meetingmanager",
            "com.teamviewer.TeamViewer",
            "com.parallels.desktop.console",
            "com.vmware.fusion"
        ]

        return knownLegitimate.contains(bundleId)
    }
}
