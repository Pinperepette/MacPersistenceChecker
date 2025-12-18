import Foundation

/// Scanner per Shell Startup Files - file di configurazione shell eseguiti al login
/// Vettore di persistenza molto comune negli attacchi
final class ShellStartupScanner: PersistenceScanner {
    let category: PersistenceCategory = .shellStartupFiles
    let requiresFullDiskAccess: Bool = true // Per leggere /etc/ files

    private let home = FileManager.default.homeDirectoryForCurrentUser

    var monitoredPaths: [URL] {
        [
            // User Zsh files
            home.appendingPathComponent(".zshrc"),
            home.appendingPathComponent(".zprofile"),
            home.appendingPathComponent(".zshenv"),
            home.appendingPathComponent(".zlogin"),
            home.appendingPathComponent(".zlogout"),
            // User Bash files
            home.appendingPathComponent(".bashrc"),
            home.appendingPathComponent(".bash_profile"),
            home.appendingPathComponent(".bash_login"),
            home.appendingPathComponent(".bash_logout"),
            home.appendingPathComponent(".profile"),
            // System-wide files
            URL(fileURLWithPath: "/etc/zshrc"),
            URL(fileURLWithPath: "/etc/zprofile"),
            URL(fileURLWithPath: "/etc/zshenv"),
            URL(fileURLWithPath: "/etc/profile"),
            URL(fileURLWithPath: "/etc/bashrc"),
            URL(fileURLWithPath: "/etc/paths"),
            URL(fileURLWithPath: "/etc/paths.d"),
            // Environment files
            home.appendingPathComponent(".MacOSX/environment.plist")
        ]
    }

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Scan individual shell startup files
        for fileURL in monitoredPaths {
            if fileURL.path.hasSuffix(".d") || fileURL.path.hasSuffix("paths.d") {
                // Scan directory
                items.append(contentsOf: await scanDirectory(fileURL))
            } else {
                // Scan single file
                if let item = await scanShellFile(fileURL) {
                    items.append(item)
                }
            }
        }

        // Also scan /etc/profile.d if it exists
        let profileD = URL(fileURLWithPath: "/etc/profile.d")
        items.append(contentsOf: await scanDirectory(profileD))

        return items
    }

    // MARK: - File Scanning

    private func scanShellFile(_ fileURL: URL) async -> PersistenceItem? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        // Read file content
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let analysis = analyzeShellContent(content)
        let isSystemFile = fileURL.path.hasPrefix("/etc/")

        var item = PersistenceItem(
            identifier: fileURL.path,
            category: .shellStartupFiles,
            name: fileURL.lastPathComponent,
            plistPath: fileURL  // Using plistPath to store config file location
        )

        // Extract any executables found in the file
        if let firstExec = analysis.executables.first {
            item.executablePath = URL(fileURLWithPath: firstExec)
        }

        // Store suspicious indicators in programArguments
        if !analysis.suspiciousPatterns.isEmpty {
            item.programArguments = analysis.suspiciousPatterns
        }

        // Get timestamps
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            item.plistModifiedAt = attrs[.modificationDate] as? Date
        }

        item.isEnabled = true

        // Set trust level based on analysis
        if isSystemFile && !analysis.hasSuspiciousContent {
            item.trustLevel = .apple
        } else if analysis.hasSuspiciousContent {
            item.trustLevel = .suspicious
        }

        // Store analysis summary in workingDirectory (for display)
        item.workingDirectory = analysis.summary

        return item
    }

    private func scanDirectory(_ dirURL: URL) async -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        guard FileManager.default.fileExists(atPath: dirURL.path) else {
            return items
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            for fileURL in contents {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    continue
                }

                if let item = await scanShellFile(fileURL) {
                    items.append(item)
                }
            }
        } catch {
            // Permission denied is expected
        }

        return items
    }

    // MARK: - Content Analysis

    private struct ShellAnalysis {
        var executables: [String] = []
        var suspiciousPatterns: [String] = []
        var hasSuspiciousContent: Bool = false
        var summary: String = ""
    }

    private func analyzeShellContent(_ content: String) -> ShellAnalysis {
        var analysis = ShellAnalysis()
        var patterns: [String] = []

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Check for suspicious patterns
            checkSuspiciousPatterns(trimmed, analysis: &analysis, patterns: &patterns)

            // Extract executables
            extractExecutables(from: trimmed, analysis: &analysis)
        }

        analysis.suspiciousPatterns = patterns
        analysis.hasSuspiciousContent = !patterns.isEmpty
        analysis.summary = patterns.isEmpty ? "No suspicious patterns detected" : "\(patterns.count) suspicious pattern(s) found"

        return analysis
    }

    private func checkSuspiciousPatterns(_ line: String, analysis: inout ShellAnalysis, patterns: inout [String]) {
        let suspiciousIndicators: [(pattern: String, description: String)] = [
            // Network activity
            ("curl ", "Network download (curl)"),
            ("wget ", "Network download (wget)"),
            ("nc ", "Netcat connection"),
            ("ncat ", "Ncat connection"),
            ("/dev/tcp/", "TCP socket connection"),
            ("/dev/udp/", "UDP socket connection"),

            // Encoded/obfuscated content
            ("base64", "Base64 encoding/decoding"),
            ("openssl enc", "OpenSSL encryption"),
            ("eval ", "Dynamic code evaluation"),
            ("$(", "Command substitution"),
            ("`", "Backtick command substitution"),

            // Persistence mechanisms
            ("launchctl", "LaunchD manipulation"),
            ("crontab", "Cron manipulation"),
            ("defaults write", "Defaults modification"),

            // Privilege escalation
            ("sudo ", "Sudo usage"),
            ("dscl ", "Directory services"),
            ("security ", "Keychain access"),

            // File system manipulation
            ("/tmp/", "Temp directory usage"),
            ("/var/tmp/", "Var temp directory"),
            ("chmod +x", "Making file executable"),
            ("chmod 777", "World-writable permissions"),

            // Suspicious destinations
            ("~/.ssh/", "SSH directory access"),
            (".bash_history", "History file access"),

            // Known malware patterns
            ("DYLD_INSERT_LIBRARIES", "Dylib injection"),
            ("osascript", "AppleScript execution"),
            ("python -c", "Inline Python execution"),
            ("perl -e", "Inline Perl execution"),
            ("ruby -e", "Inline Ruby execution"),
        ]

        let lowercaseLine = line.lowercased()

        for indicator in suspiciousIndicators {
            if lowercaseLine.contains(indicator.pattern.lowercased()) {
                if !patterns.contains(indicator.description) {
                    patterns.append(indicator.description)
                }
            }
        }
    }

    private func extractExecutables(from line: String, analysis: inout ShellAnalysis) {
        // Look for absolute paths to executables
        let pathPattern = #"/[a-zA-Z0-9._/-]+"#

        if let regex = try? NSRegularExpression(pattern: pathPattern, options: []) {
            let range = NSRange(line.startIndex..., in: line)
            let matches = regex.matches(in: line, options: [], range: range)

            for match in matches {
                if let matchRange = Range(match.range, in: line) {
                    let path = String(line[matchRange])
                    // Only add if it looks like an executable path
                    if path.hasPrefix("/") && !path.hasSuffix("/") {
                        if !analysis.executables.contains(path) {
                            analysis.executables.append(path)
                        }
                    }
                }
            }
        }
    }
}
