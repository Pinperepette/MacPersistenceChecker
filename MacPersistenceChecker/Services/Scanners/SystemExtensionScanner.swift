import Foundation

/// Scanner per System Extensions
final class SystemExtensionScanner: PersistenceScanner {
    let category: PersistenceCategory = .systemExtensions
    let requiresFullDiskAccess: Bool = false

    var monitoredPaths: [URL] {
        [
            URL(fileURLWithPath: "/Library/SystemExtensions")
        ]
    }

    func scan() async throws -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        // Use systemextensionsctl to get the list of extensions
        let output = await runSystemExtensionsCtl()
        items.append(contentsOf: parseSystemExtensionsOutput(output))

        return items
    }

    private func runSystemExtensionsCtl() async -> String {
        await CommandRunner.run("/usr/bin/systemextensionsctl", arguments: ["list"], timeout: 5.0)
    }

    private func parseSystemExtensionsOutput(_ output: String) -> [PersistenceItem] {
        var items: [PersistenceItem] = []

        let lines = output.components(separatedBy: "\n")

        for line in lines {
            // Skip headers and separators
            if line.isEmpty || line.contains("---") || line.starts(with: "#") {
                continue
            }

            // Parse line - format varies but typically:
            // enabled/disabled | activated | teamID | bundleID | version | path/state
            // Or: * [state] bundleID (version) teamID path

            // Try to extract relevant information
            if let item = parseExtensionLine(line) {
                items.append(item)
            }
        }

        return items
    }

    private func parseExtensionLine(_ line: String) -> PersistenceItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Pattern 1: "* [enabled]  com.company.extension (1.0)  TEAMID  /path"
        // Pattern 2: "enabled  activated  TEAMID  com.company.extension  1.0  /path"

        // Try to find bundle identifier pattern (com.something.something)
        guard let bundleId = extractBundleId(from: trimmed) else {
            return nil
        }

        // Skip if it looks like a file path instead of bundle ID
        if bundleId.contains("/") {
            return nil
        }

        var item = PersistenceItem(
            identifier: bundleId,
            category: .systemExtensions,
            name: extractName(from: bundleId)
        )

        // Determine state
        item.isEnabled = trimmed.contains("enabled") || trimmed.starts(with: "*")
        item.isLoaded = trimmed.contains("activated") || trimmed.contains("[activated")

        // Try to extract version from parentheses
        if let openParen = trimmed.firstIndex(of: "("),
           let closeParen = trimmed.firstIndex(of: ")"),
           openParen < closeParen {
            let versionStart = trimmed.index(after: openParen)
            let version = String(trimmed[versionStart..<closeParen])
            if version.allSatisfy({ $0.isNumber || $0 == "." }) {
                item.version = version
            }
        }

        // Try to extract team ID (10 char alphanumeric)
        if let teamId = extractTeamId(from: trimmed) {
            item.signatureInfo = SignatureInfo(
                isSigned: true,
                isValid: true,
                isAppleSigned: false,
                isNotarized: true,
                hasHardenedRuntime: true,
                teamIdentifier: teamId,
                bundleIdentifier: bundleId,
                commonName: nil,
                organizationName: nil,
                certificateExpirationDate: nil,
                isCertificateExpired: false,
                signingAuthority: nil,
                codeDirectoryHash: nil,
                flags: nil
            )
        }

        // Try to extract path
        if let pathStart = trimmed.range(of: "/"),
           let pathEnd = trimmed.range(of: ".systemextension") {
            let fullPath = String(trimmed[pathStart.lowerBound...pathEnd.upperBound])
            if !fullPath.contains(" ") {
                item.executablePath = URL(fileURLWithPath: fullPath)
            }
        }

        return item
    }

    private func extractBundleId(from text: String) -> String? {
        // Look for com.something.something pattern
        let words = text.split(whereSeparator: { $0.isWhitespace })
        for word in words {
            let str = String(word)
            if str.contains(".") && !str.hasPrefix("/") && !str.hasPrefix("(") {
                let components = str.split(separator: ".")
                if components.count >= 2 {
                    return str
                }
            }
        }
        return nil
    }

    private func extractTeamId(from text: String) -> String? {
        // Look for 10-character alphanumeric team ID
        let words = text.split(whereSeparator: { $0.isWhitespace })
        for word in words {
            let str = String(word)
            if str.count == 10 && str.allSatisfy({ $0.isLetter || $0.isNumber }) && str.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                return str
            }
        }
        return nil
    }

    private func extractName(from bundleId: String) -> String {
        // Extract meaningful name from bundle ID
        let components = bundleId.split(separator: ".")

        // Take last 1-2 components that look like a name
        var nameComponents: [String] = []
        for component in components.reversed() {
            let comp = String(component)
            // Skip common suffixes
            if ["extension", "systemextension", "sysext", "driver"].contains(comp.lowercased()) {
                continue
            }
            nameComponents.insert(comp, at: 0)
            if nameComponents.count >= 2 {
                break
            }
        }

        return nameComponents.isEmpty ? bundleId : nameComponents.joined(separator: " ")
    }
}
