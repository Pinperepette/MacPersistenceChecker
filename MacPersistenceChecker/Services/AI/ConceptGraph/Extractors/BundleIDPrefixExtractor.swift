import Foundation

/// Emits `pattern:*` concepts for known bundle-ID prefixes (e.g. `com.apple.`,
/// `homebrew.mxcl.`). Reads the same `ConceptHints.json` resource as the path
/// extractor.
struct BundleIDPrefixExtractor: ConceptFeatureExtractor {
    let name = "BundleIDPrefixExtractor"
    let version: Int

    private let hints: [BundleHint]

    init() {
        let loaded = ConceptHintsLoader.shared.load()
        self.hints = loaded.bundleHints
        self.version = loaded.version
    }

    func extract(from item: PersistenceItem) -> [ConceptSignal] {
        // Look at both bundleIdentifier and the bare identifier (some scanners
        // populate identifier with the launchctl label, e.g. `homebrew.mxcl.foo`).
        let candidates: [String] = [item.bundleIdentifier, item.identifier].compactMap { $0 }

        guard !candidates.isEmpty else { return [] }

        var out: [ConceptSignal] = []
        var seen: Set<String> = []

        for hint in hints {
            for candidate in candidates {
                if candidate.hasPrefix(hint.prefix), !seen.contains(hint.id) {
                    seen.insert(hint.id)
                    out.append(ConceptSignal(
                        conceptID: hint.id,
                        displayName: hint.displayName,
                        kind: .pattern,
                        signal: "bundleIDPrefix=\(hint.prefix)",
                        attributes: ["prefix": hint.prefix]
                    ))
                    break
                }
            }
        }

        return out
    }
}
