import Foundation
import CryptoKit
import GRDB

/// In-memory cluster computed from the concept ingestor's associations.
/// Carries enough info for the Smart Triage UI to make decisions without
/// loading anything from disk.
struct ConceptCluster: Identifiable, Equatable {
    let id: String                       // = signatureHash
    let signatureHash: String
    let conceptIDs: [String]
    let memberFingerprints: [String]
    let memberItems: [PersistenceItem]   // resolved items (full objects)
    let sampleItems: [PersistenceItem]   // up to 5 highest-risk samples
    let currentVerdict: KnowledgeVerdict?
    let needsClassification: Bool

    /// True if any concept in the cluster already carries an AI-sourced
    /// verdict (clusterAI or aiExtracted). Even if the verdict's confidence
    /// is below the resolver gate, the AI has already spoken — we exclude
    /// such clusters from subsequent AI batch runs to avoid infinite re-tries.
    let aiAnalyzed: Bool

    /// Human label assembled from the most informative concepts in the
    /// signature (vendor / software preferred over mechanism / path).
    let displayLabel: String
}

/// Builds clusters of items that share the same set of linked concept IDs.
/// One cluster = one decision unit for the user (or for an AI batch call).
final class ClusterBuilder: @unchecked Sendable {
    static let shared = ClusterBuilder()

    private let ingestor: ConceptIngestor
    private let conceptStore: ConceptStore
    private let resolver: ConceptResolver

    /// Cache for `buildClusters`: skips the entire compute path when neither
    /// the items collection nor the rule/verdict graph have changed since the
    /// last build. Refresh on the same scan therefore returns instantly.
    private let cacheLock = NSLock()
    private var cachedSignature: String?
    private var cachedClusters: [ConceptCluster] = []

    init(
        ingestor: ConceptIngestor = .shared,
        conceptStore: ConceptStore = .shared,
        resolver: ConceptResolver = .shared
    ) {
        self.ingestor = ingestor
        self.conceptStore = conceptStore
        self.resolver = resolver
    }

    /// Invalidate the build cache. Call after Trust/Watch/Block on a cluster
    /// or after AI batch analysis so the next Refresh recomputes verdicts.
    func invalidateCache() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedSignature = nil
        cachedClusters = []
    }

    /// Build clusters from the given items. The set is stable across calls as
    /// long as concept extractions don't change (signature is the sorted list
    /// of concept IDs). Items without any concept signals end up in a single
    /// `(empty signature)` cluster.
    func buildClusters(from items: [PersistenceItem]) -> [ConceptCluster] {
        // Cache fast-path: identical inputs + identical graph state ⇒ reuse
        // the previous result. Avoids ~300-800ms of compute on a no-op
        // Refresh tap, which is the most common case once the user has
        // settled on a triage state.
        let signature = Self.cacheSignature(items: items)
        cacheLock.lock()
        if let cached = cachedSignature, cached == signature {
            let result = cachedClusters
            cacheLock.unlock()
            return result
        }
        cacheLock.unlock()

        // Group by signature.
        var groups: [String: (ids: [String], items: [PersistenceItem], fingerprints: [String])] = [:]
        for item in items {
            let fingerprint = ItemFingerprint.make(from: item).hash
            let conceptIDs = ingestor.conceptIDs(forFingerprint: fingerprint).sorted()
            let signature = conceptIDs.joined(separator: ",")
            if groups[signature] == nil {
                groups[signature] = (conceptIDs, [], [])
            }
            groups[signature]?.items.append(item)
            groups[signature]?.fingerprints.append(fingerprint)
        }

        // Single fetch: which concepts have *any* AI-sourced verdict attached?
        // Used to mark clusters as `aiAnalyzed` so we don't keep re-sending
        // the same cluster to AI when its verdict was below the resolver gate.
        let aiAnalyzedConceptIDs = Self.conceptIDsWithAIVerdict()

        let now = Date()
        var clusters: [ConceptCluster] = []
        var clusterRecords: [ClusterRecord] = []
        for (signature, group) in groups {
            let signatureHash = Self.hash(signature)
            let sample = sampleHighRiskItems(group.items)
            let resolved = group.items.first.map { item -> ResolvedVerdict in
                resolver.resolve(item: item, linkedConceptIDs: group.ids)
            }
            var verdict: KnowledgeVerdict?
            if case .classified(let v, _) = resolved?.outcome { verdict = v }
            let needsClassification: Bool
            switch resolved?.outcome {
            case .classified: needsClassification = false
            default:          needsClassification = true
            }

            let aiAnalyzed = group.ids.contains { aiAnalyzedConceptIDs.contains($0) }

            let cluster = ConceptCluster(
                id: signatureHash,
                signatureHash: signatureHash,
                conceptIDs: group.ids,
                memberFingerprints: group.fingerprints,
                memberItems: group.items,
                sampleItems: sample,
                currentVerdict: verdict,
                needsClassification: needsClassification,
                aiAnalyzed: aiAnalyzed,
                displayLabel: composeDisplayLabel(conceptIDs: group.ids)
            )
            clusters.append(cluster)

            clusterRecords.append(ClusterRecord(
                signatureHash: signatureHash,
                conceptIDs: group.ids,
                memberCount: group.items.count,
                currentVerdict: verdict,
                lastClassifiedAt: verdict != nil ? now : nil
            ))
        }

        // Persist all cluster records in a single write transaction. 100x
        // faster than one transaction per cluster on a 300-cluster scan.
        try? upsertClusters(clusterRecords)

        // Highest count first — UI scans from the most impactful cluster down.
        let sorted = clusters.sorted { $0.memberItems.count > $1.memberItems.count }

        // Update cache for the next call.
        cacheLock.lock()
        cachedSignature = signature
        cachedClusters = sorted
        cacheLock.unlock()

        return sorted
    }

    /// Computes a cheap signature representing the inputs the build depends on:
    /// the count and id sum of items, and the count of AI/user verdicts. Any
    /// change to either invalidates the cache, while a no-op refresh returns
    /// the cached result instantly.
    private static func cacheSignature(items: [PersistenceItem]) -> String {
        let itemHash = items.reduce(into: 0) { acc, item in
            acc &+= item.id.hashValue
        }
        let verdictCount = (try? DatabaseManager.shared.dbQueue?.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM concept_verdicts") ?? 0
        }) ?? 0
        let ruleCount = (try? DatabaseManager.shared.dbQueue?.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledgeRules") ?? 0
        }) ?? 0
        return "\(items.count):\(itemHash):\(verdictCount):\(ruleCount)"
    }

    // MARK: - Persistence

    /// Returns the set of concept IDs that have at least one AI-sourced
    /// concept_verdict (clusterAI or aiExtracted). Single SQL query, used to
    /// flag clusters as already-AI-analyzed.
    private static func conceptIDsWithAIVerdict() -> Set<String> {
        guard let dbQueue = DatabaseManager.shared.dbQueue else { return [] }
        let sources = [
            ConceptVerdictSource.aiExtracted.rawValue,
            ConceptVerdictSource.clusterAI.rawValue
        ]
        let placeholders = sources.map { _ in "?" }.joined(separator: ",")
        let ids = (try? dbQueue.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT concept_id FROM concept_verdicts WHERE source IN (\(placeholders))",
                arguments: StatementArguments(sources)
            )
        }) ?? []
        return Set(ids)
    }

    private func upsertClusters(_ records: [ClusterRecord]) throws {
        guard !records.isEmpty,
              let dbQueue = DatabaseManager.shared.dbQueue else { return }
        try dbQueue.write { db in
            for record in records {
                try record.insert(db, onConflict: .replace)
            }
        }
    }

    // MARK: - Sample selection

    private func sampleHighRiskItems(_ items: [PersistenceItem]) -> [PersistenceItem] {
        let sorted = items.sorted { ($0.riskScore ?? 0) > ($1.riskScore ?? 0) }
        return Array(sorted.prefix(5))
    }

    // MARK: - Label composition

    /// Builds a short, human-friendly label by picking the most informative
    /// concept from the signature. Priority: software → vendor → pattern →
    /// path → mechanism. Falls back to "Unclassified items" when no concepts
    /// are linked.
    private func composeDisplayLabel(conceptIDs: [String]) -> String {
        guard !conceptIDs.isEmpty else { return "Unclassified items" }

        let priorityOrder: [String] = ["software:", "vendor:", "pattern:", "path:", "mechanism:"]
        for prefix in priorityOrder {
            if let id = conceptIDs.first(where: { $0.hasPrefix(prefix) }),
               let concept = conceptStore.cachedConcept(id: id) {
                let kindLabel = concept.kind.rawValue
                return "\(concept.displayName) — \(kindLabel)"
            }
        }
        // Last resort: raw first concept.
        return conceptIDs.first ?? "Unknown"
    }

    // MARK: - Hashing

    private static func hash(_ signature: String) -> String {
        let digest = SHA256.hash(data: Data(signature.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
