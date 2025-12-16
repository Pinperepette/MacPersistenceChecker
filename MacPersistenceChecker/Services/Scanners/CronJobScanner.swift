import Foundation

/// Scanner per Cron Jobs
final class CronJobScanner: PersistenceScanner {
    let category: PersistenceCategory = .cronJobs
    let requiresFullDiskAccess: Bool = true

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/var/at/tabs"),
            URL(fileURLWithPath: "/usr/lib/cron/tabs"),
            URL(fileURLWithPath: "/private/var/at/tabs")
        ]
    }

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Scan crontab files for all users
        items.append(contentsOf: await scanCrontabs())

        // Scan system cron directories
        items.append(contentsOf: await scanSystemCronDirs())

        // Scan at jobs
        items.append(contentsOf: await scanAtJobs())

        return items
    }

    private func scanCrontabs() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Get current user's crontab
        let userCrontab = await runCrontab(forUser: nil)
        if !userCrontab.isEmpty {
            let userItems = parseCrontab(userCrontab, source: "User crontab")
            items.append(contentsOf: userItems)
        }

        // Try to read root crontab (requires privileges)
        let rootCrontab = await runCrontab(forUser: "root")
        if !rootCrontab.isEmpty {
            let rootItems = parseCrontab(rootCrontab, source: "Root crontab")
            items.append(contentsOf: rootItems)
        }

        // Scan crontab files directly
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

                for crontabURL in contents {
                    if let content = try? String(contentsOf: crontabURL, encoding: .utf8) {
                        let tabItems = parseCrontab(content, source: crontabURL.lastPathComponent)
                        items.append(contentsOf: tabItems)
                    }
                }
            } catch {
                // Permission denied is expected for some directories
            }
        }

        return items
    }

    private func scanSystemCronDirs() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        let systemCronDirs = [
            "/etc/cron.d",
            "/etc/cron.daily",
            "/etc/cron.hourly",
            "/etc/cron.weekly",
            "/etc/cron.monthly",
            "/usr/local/etc/cron.d"
        ]

        for dirPath in systemCronDirs {
            let dirURL = URL(fileURLWithPath: dirPath)
            guard FileManager.default.fileExists(atPath: dirPath) else {
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: []
                )

                for fileURL in contents {
                    // Skip non-executable or hidden files
                    if fileURL.lastPathComponent.hasPrefix(".") {
                        continue
                    }

                    var item = PersistenceItem(
                        identifier: "\(dirPath)/\(fileURL.lastPathComponent)",
                        category: .cronJobs,
                        name: fileURL.lastPathComponent,
                        executablePath: fileURL
                    )

                    // Determine schedule from directory name
                    item.workingDirectory = dirPath
                    if dirPath.contains("daily") {
                        item.programArguments = ["@daily"]
                    } else if dirPath.contains("hourly") {
                        item.programArguments = ["@hourly"]
                    } else if dirPath.contains("weekly") {
                        item.programArguments = ["@weekly"]
                    } else if dirPath.contains("monthly") {
                        item.programArguments = ["@monthly"]
                    }

                    // Get timestamps
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
                        item.binaryModifiedAt = attrs[.modificationDate] as? Date
                    }

                    item.isEnabled = true
                    items.append(item)
                }
            } catch {
                // Permission denied
            }
        }

        return items
    }

    private func scanAtJobs() async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // List at jobs using atq
        let output = await runCommand("/usr/bin/atq", arguments: [])
        if output.isEmpty {
            return items
        }

        // Parse atq output: job_id date time queue user
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let components = line.split(whereSeparator: { $0.isWhitespace })
            guard components.count >= 2 else { continue }

            let jobId = String(components[0])

            var item = PersistenceItem(
                identifier: "at-job-\(jobId)",
                category: .cronJobs,
                name: "At Job #\(jobId)"
            )

            // Extract scheduled time if present
            if components.count >= 5 {
                let dateTime = components[1...4].joined(separator: " ")
                item.programArguments = [dateTime]
            }

            item.isEnabled = true
            items.append(item)
        }

        return items
    }

    // MARK: - Helpers

    private func runCrontab(forUser user: String?) async -> String {
        await runCommand("/usr/bin/crontab", arguments: user != nil ? ["-u", user!, "-l"] : ["-l"])
    }

    private func runCommand(_ path: String, arguments: [String]) async -> String {
        await CommandRunner.run(path, arguments: arguments, timeout: 3.0)
    }

    private func parseCrontab(_ content: String, source: String) -> [PersistenceItem] {
        var items: [PersistenceItem] = []
        var itemIndex = 0

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Skip variable assignments
            if trimmed.contains("=") && !trimmed.contains(" ") {
                continue
            }

            itemIndex += 1

            // Parse cron entry
            // Format: minute hour day month weekday command
            // Or special: @reboot, @daily, etc.

            var schedule: String
            var command: String

            if trimmed.hasPrefix("@") {
                // Special schedule
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                schedule = String(parts[0])
                command = parts.count > 1 ? String(parts[1]) : ""
            } else {
                // Standard cron format
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 6 {
                    schedule = parts[0...4].joined(separator: " ")
                    command = parts[5...].joined(separator: " ")
                } else {
                    continue
                }
            }

            // Extract executable from command
            let executable = extractExecutable(from: command)

            var item = PersistenceItem(
                identifier: "\(source)-\(itemIndex)",
                category: .cronJobs,
                name: "\(source): \(executable ?? String(command.prefix(30)))"
            )

            if let execPath = executable {
                item.executablePath = URL(fileURLWithPath: execPath)
            }

            item.programArguments = [schedule, command]
            item.isEnabled = true

            items.append(item)
        }

        return items
    }

    private func extractExecutable(from command: String) -> String? {
        // Handle various command formats
        var cmd = command.trimmingCharacters(in: .whitespaces)

        // Remove leading env vars
        while cmd.contains("=") {
            if let spaceIndex = cmd.firstIndex(of: " ") {
                cmd = String(cmd[cmd.index(after: spaceIndex)...])
            } else {
                break
            }
        }

        // Get first component
        let parts = cmd.split(separator: " ")
        guard let first = parts.first else { return nil }

        let executable = String(first)

        // Return if it looks like a path
        if executable.hasPrefix("/") || executable.hasPrefix(".") {
            return executable
        }

        // Try to resolve in PATH
        // For simplicity, just return the command name
        return executable
    }
}
