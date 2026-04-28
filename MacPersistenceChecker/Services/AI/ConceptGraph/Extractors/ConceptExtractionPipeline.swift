import Foundation

/// One concept signal emitted by an extractor for a given item.
struct ConceptSignal: Equatable {
    let conceptID: String
    let displayName: String
    let kind: ConceptKind
    /// Diagnostic note describing why the extractor matched.
    let signal: String
    /// Optional structured attributes (kind-specific, e.g. teamID).
    let attributes: [String: String]

    init(
        conceptID: String,
        displayName: String,
        kind: ConceptKind,
        signal: String,
        attributes: [String: String] = [:]
    ) {
        self.conceptID = conceptID
        self.displayName = displayName
        self.kind = kind
        self.signal = signal
        self.attributes = attributes
    }
}

/// A single deterministic feature extractor. Stateless. Versioned so changes
/// to its emission rules force re-extraction across the graph.
protocol ConceptFeatureExtractor: Sendable {
    var name: String { get }
    var version: Int { get }
    func extract(from item: PersistenceItem) -> [ConceptSignal]
}

/// Composes the configured feature extractors and produces deduplicated
/// signals per item. The pipeline's effective version is derived from the
/// versions of its members so any change invalidates downstream caches.
final class ConceptExtractionPipeline: Sendable {
    static let shared = ConceptExtractionPipeline()

    let extractors: [any ConceptFeatureExtractor]
    let version: Int

    init(extractors: [any ConceptFeatureExtractor]? = nil) {
        let defaults: [any ConceptFeatureExtractor] = [
            VendorExtractor(),
            PathPrefixExtractor(),
            BundleIDPrefixExtractor(),
            FilenamePatternExtractor(),
            MechanismExtractor(),
            SoftwareExtractor()
        ]
        let resolved = extractors ?? defaults
        self.extractors = resolved
        // Pipeline version = sum of member versions (changes when any member bumps).
        self.version = resolved.reduce(0) { $0 + $1.version }
    }

    /// Run all extractors and deduplicate by concept ID. If two extractors
    /// emit the same concept ID, the first wins; subsequent signals are
    /// preserved only as alternative attribute hints.
    func extract(from item: PersistenceItem) -> [ConceptSignal] {
        var seen: Set<String> = []
        var out: [ConceptSignal] = []
        for extractor in extractors {
            for signal in extractor.extract(from: item) where !seen.contains(signal.conceptID) {
                seen.insert(signal.conceptID)
                out.append(signal)
            }
        }
        return out
    }
}
