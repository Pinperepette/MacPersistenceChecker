import Foundation

/// Drives concept extraction over the current scan and populates the graph
/// (concepts, links, item_concepts). Builds the in-memory
/// `fingerprint → concept IDs` cache that the filter pipeline uses for
/// O(1) lookups during UI updates.
///
/// All disk work runs off-main; the in-memory associations are updated under
/// a lock so the UI can read consistent snapshots.
final class ConceptIngestor: @unchecked Sendable {
    static let shared = ConceptIngestor()

    private let pipeline: ConceptExtractionPipeline
    private let conceptStore: ConceptStore

    private let lock = NSLock()
    private var assocByFingerprint: [String: [String]] = [:]
    private var lastIngestAt: Date?
    private var lastPipelineVersion: Int?

    private init(
        pipeline: ConceptExtractionPipeline = .shared,
        conceptStore: ConceptStore = .shared
    ) {
        self.pipeline = pipeline
        self.conceptStore = conceptStore
    }

    /// Snapshot of the in-memory association table.
    func conceptIDs(forFingerprint hash: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return assocByFingerprint[hash] ?? []
    }

    /// Last successful ingest timestamp, for UI status.
    var lastRunAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return lastIngestAt
    }

    /// Run the extraction over the items (typically `appState.items`) and
    /// persist the results. Single extraction pass — both the in-memory cache
    /// and the DB rows are built from the same scan. All concept upserts and
    /// all item-concept associations are written in **one transaction each**
    /// (was ~27000 transactions for a 6800-item scan; now 3 total).
    @discardableResult
    func ingest(items: [PersistenceItem]) async -> IngestResult {
        let start = Date()
        let pipeline = self.pipeline
        let store = self.conceptStore
        let extractorVersion = pipeline.version

        struct PreparedIngest {
            let conceptsByID: [String: Concept]
            let associations: [(fingerprintHash: String, conceptID: String, signal: String?)]
            let assocByFingerprint: [String: [String]]
        }

        // Single off-main pass: extract, build DB write payloads, build the
        // in-memory association table.
        let prepared: PreparedIngest = await Task.detached(priority: .userInitiated) {
            var conceptsByID: [String: Concept] = [:]
            var associations: [(String, String, String?)] = []
            var assoc: [String: [String]] = [:]

            for item in items {
                let signals = pipeline.extract(from: item)
                guard !signals.isEmpty else { continue }
                let fingerprint = ItemFingerprint.make(from: item).hash

                for signal in signals {
                    if conceptsByID[signal.conceptID] == nil {
                        conceptsByID[signal.conceptID] = Concept.make(
                            id: signal.conceptID,
                            kind: signal.kind,
                            displayName: signal.displayName,
                            extractorVersion: extractorVersion,
                            attributes: signal.attributes,
                            now: start
                        )
                    }
                    associations.append((fingerprint, signal.conceptID, signal.signal))
                }
                assoc[fingerprint] = signals.map(\.conceptID)
            }

            return PreparedIngest(
                conceptsByID: conceptsByID,
                associations: associations,
                assocByFingerprint: assoc
            )
        }.value

        // Persist in a small number of large transactions, off main.
        let result: IngestResult = await Task.detached(priority: .userInitiated) {
            try? store.batchUpsertConcepts(Array(prepared.conceptsByID.values))
            try? store.batchRecordAssociations(
                prepared.associations,
                extractorVersion: extractorVersion,
                atDate: start
            )

            // Compute deterministic edges (prefix subsumes/instanceOf) over
            // the *concepts we just touched* — no need to re-fetch the entire
            // table.
            let edges = ConceptIngestor.computeDeterministicEdges(
                concepts: Array(prepared.conceptsByID.values),
                createdAt: start
            )
            try? store.batchUpsertLinks(edges)

            return IngestResult(
                itemsScanned: items.count,
                conceptsTouched: prepared.conceptsByID.count,
                associations: prepared.associations.count,
                edgesCreated: edges.count,
                elapsed: Date().timeIntervalSince(start)
            )
        }.value

        // Swap in the new in-memory association table.
        lock.lock()
        assocByFingerprint = prepared.assocByFingerprint
        lastIngestAt = Date()
        lastPipelineVersion = extractorVersion
        lock.unlock()

        // Refresh downstream caches.
        conceptStore.preload()
        ConceptResolver.shared.invalidate()

        return result
    }

    /// Computes deterministic `subsumes` / `instance-of` edges between concepts
    /// whose IDs share a prefix relationship (e.g. `pattern:com.apple` subsumes
    /// `pattern:com.apple.driver`). Returns the edges; the caller batches the
    /// write.
    private static func computeDeterministicEdges(
        concepts: [Concept],
        createdAt: Date
    ) -> [ConceptLink] {
        var edges: [ConceptLink] = []
        // Group concepts by kind so we only relate within the same kind.
        let byKind = Dictionary(grouping: concepts) { $0.kind }

        for (_, group) in byKind {
            let ids = group.map(\.id)
            for child in ids {
                for parent in ids where parent != child {
                    if child.hasPrefix(parent + ".") || child.hasPrefix(parent + "/") {
                        edges.append(ConceptLink(
                            fromID: parent, toID: child,
                            relation: .subsumes, source: .deterministic,
                            weight: 1.0, createdAt: createdAt
                        ))
                        edges.append(ConceptLink(
                            fromID: child, toID: parent,
                            relation: .instanceOf, source: .deterministic,
                            weight: 1.0, createdAt: createdAt
                        ))
                    }
                }
            }
        }
        return edges
    }
}

struct IngestResult: Equatable {
    let itemsScanned: Int
    let conceptsTouched: Int
    let associations: Int
    let edgesCreated: Int
    let elapsed: TimeInterval
}
