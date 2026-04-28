import Foundation

/// Matches the executable filename against regex hints (e.g. `lib*.dylib`
/// versioned, `*Helper.app`, reverse-DNS plists). Driven by `ConceptHints.json`.
struct FilenamePatternExtractor: ConceptFeatureExtractor {
    let name = "FilenamePatternExtractor"
    let version: Int

    private let hints: [FilenameHint]

    init() {
        let loaded = ConceptHintsLoader.shared.load()
        self.hints = loaded.filenamePatterns
        self.version = loaded.version
    }

    func extract(from item: PersistenceItem) -> [ConceptSignal] {
        let candidates: [String] = [
            item.executablePath?.lastPathComponent,
            item.plistPath?.lastPathComponent
        ].compactMap { $0 }

        guard !candidates.isEmpty else { return [] }

        var out: [ConceptSignal] = []
        var seen: Set<String> = []

        for hint in hints {
            guard let regex = hint.compiledRegex else { continue }
            for filename in candidates {
                let range = NSRange(filename.startIndex..., in: filename)
                if regex.firstMatch(in: filename, range: range) != nil, !seen.contains(hint.id) {
                    seen.insert(hint.id)
                    out.append(ConceptSignal(
                        conceptID: hint.id,
                        displayName: hint.displayName,
                        kind: .pattern,
                        signal: "filenameMatches=\(hint.regex)",
                        attributes: ["regex": hint.regex]
                    ))
                    break
                }
            }
        }

        return out
    }
}
