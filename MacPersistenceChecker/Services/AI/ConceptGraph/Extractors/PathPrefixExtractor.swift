import Foundation

/// Loads path-prefix hints from `Resources/ConceptHints.json` and emits a
/// `pathCategory` concept for each known prefix that the item's plist or
/// executable path matches. The hints file is a versioned bundle resource so
/// it can be updated without code changes.
struct PathPrefixExtractor: ConceptFeatureExtractor {
    let name = "PathPrefixExtractor"
    let version: Int

    private let hints: [PathHint]

    init() {
        let loaded = ConceptHintsLoader.shared.load()
        self.hints = loaded.pathHints
        self.version = loaded.version
    }

    func extract(from item: PersistenceItem) -> [ConceptSignal] {
        // We check both the plist path and the executable path. The plist path
        // is what defines persistence; the executable path tells us where the
        // actual binary lives (often a different directory).
        let candidatePaths: [String] = [item.plistPath?.path, item.executablePath?.path]
            .compactMap { $0 }

        guard !candidatePaths.isEmpty else { return [] }

        let homeRelative = candidatePaths.compactMap { Self.makeUserRelative($0) }

        var out: [ConceptSignal] = []
        var seen: Set<String> = []

        for hint in hints {
            let target: [String] = hint.userRelative ? homeRelative : candidatePaths
            for path in target {
                if path.hasPrefix(hint.prefix), !seen.contains(hint.id) {
                    seen.insert(hint.id)
                    out.append(ConceptSignal(
                        conceptID: hint.id,
                        displayName: hint.displayName,
                        kind: .pathCategory,
                        signal: "pathPrefix=\(hint.prefix)",
                        attributes: ["prefix": hint.prefix, "userRelative": String(hint.userRelative)]
                    ))
                    break
                }
            }
        }

        return out
    }

    /// Returns the path with the user's home directory stripped, otherwise nil.
    private static func makeUserRelative(_ path: String) -> String? {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return nil }
        return String(path.dropFirst(home.count + 1))
    }
}
