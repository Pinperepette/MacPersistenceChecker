import Foundation

/// Trivial extractor that emits a `mechanism:*` concept reflecting the item's
/// persistence category (launchAgent, launchDaemon, dylib, etc.). Always emits
/// exactly one signal — every item belongs to a mechanism.
struct MechanismExtractor: ConceptFeatureExtractor {
    let name = "MechanismExtractor"
    let version = 1

    func extract(from item: PersistenceItem) -> [ConceptSignal] {
        let raw = item.category.rawValue
        return [
            ConceptSignal(
                conceptID: "mechanism:\(raw)",
                displayName: item.category.displayName,
                kind: .mechanism,
                signal: "category=\(raw)",
                attributes: ["category": raw]
            )
        ]
    }
}
