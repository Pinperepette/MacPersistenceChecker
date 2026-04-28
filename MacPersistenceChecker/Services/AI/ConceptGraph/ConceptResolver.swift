import Foundation

/// Decision returned by `ConceptResolver` for a given item. Carries enough
/// information for the UI to explain *why* the item ended up where it did.
struct ResolvedVerdict {
    enum Outcome {
        /// At least one concept attached to this item carries a verdict that
        /// matches/exceeds the gating threshold.
        case classified(verdict: KnowledgeVerdict, confidence: Double)
        /// The item links to concepts but none of them have a verdict yet.
        case unclassified(linkedConceptIDs: [String])
        /// We have no signals for the item (extractor produced nothing or the
        /// graph is empty).
        case noSignals
    }

    let outcome: Outcome
    /// Concept that contributed the winning verdict (nil for non-classified).
    let winningConceptID: String?
    /// Rule whose verdict was used.
    let winningRuleID: String?
    /// Ordered, human-readable trace of every candidate considered. Newest
    /// first. Surfaced verbatim in the item detail view.
    let trace: [String]
}

/// Resolves the verdict for an item using the concept graph.
///
/// Algorithm — strict ladder, no ambiguity:
///   1. Gather all concepts the item is currently linked to (in-memory cache).
///   2. For each concept, fetch its attached verdicts and pick the strongest
///      live rule (decay-aware confidence).
///   3. Apply the verdict ladder across all (concept, rule) candidates:
///        a. Severity: malicious > watchlist > benign.
///        b. Within same severity: highest effective confidence.
///        c. Within same confidence: most specific concept (kind weight + ID length).
///        d. Within same specificity: user-defined > AI > seedKnownVendor.
///        e. Within same source: most recently confirmed.
///   4. Below the gating threshold (0.7), return `unclassified`.
///
/// All work is in-memory after the initial graph load — never blocks on disk
/// during a hot lookup. Used by the main filter and the live monitor gate.
final class ConceptResolver {
    static let shared = ConceptResolver()

    private let conceptStore: ConceptStore
    private let ruleStore: KnowledgeGraphStore
    private let ruleMatcher: RuleMatcher

    /// Effective-confidence threshold for `classified` outcomes. Below this
    /// we return `unclassified` even if a concept has a verdict.
    static let gatingThreshold: Double = 0.7

    init(
        conceptStore: ConceptStore = .shared,
        ruleStore: KnowledgeGraphStore = .shared,
        ruleMatcher: RuleMatcher = .shared
    ) {
        self.conceptStore = conceptStore
        self.ruleStore = ruleStore
        self.ruleMatcher = ruleMatcher
    }

    // MARK: - Public

    /// Resolves the verdict for an item using the in-memory caches built from
    /// the most recent concept extraction and rule store loads. Synchronous;
    /// safe to call from the main thread.
    func resolve(item: PersistenceItem, linkedConceptIDs: [String]) -> ResolvedVerdict {
        // Fetch concepts from the cache. Anything not in the cache is silently
        // dropped — the caller has access to the most recent associations.
        let concepts = linkedConceptIDs.compactMap { conceptStore.cachedConcept(id: $0) }
        guard !concepts.isEmpty else {
            return ResolvedVerdict(
                outcome: .noSignals,
                winningConceptID: nil,
                winningRuleID: nil,
                trace: ["no concept signals for this item"]
            )
        }

        // Pull rules + verdicts from in-memory snapshots (5s TTL). Critical:
        // resolve() runs once per filtered item — calling fetchAll on every
        // call would be 6800+ SQL queries on the main thread per filter pass.
        let rulesByID = loadRulesByIDCached()
        let verdictsByConcept = loadAllVerdictsCached()

        // Build candidates: each (concept, rule) pair where the rule is live.
        var candidates: [Candidate] = []
        var trace: [String] = []
        var unclassifiedConceptIDs: [String] = []

        for concept in concepts {
            let verdicts = verdictsByConcept[concept.id] ?? []
            if verdicts.isEmpty {
                unclassifiedConceptIDs.append(concept.id)
                trace.append("• \(concept.id) [\(concept.kind.rawValue)] — no verdict attached")
                continue
            }
            for verdict in verdicts {
                guard let rule = rulesByID[verdict.ruleID], !rule.disabled else { continue }
                let confidence = ruleMatcher.currentConfidence(of: rule)
                let candidate = Candidate(
                    conceptID: concept.id,
                    conceptKind: concept.kind,
                    rule: rule,
                    verdict: rule.verdict,
                    confidence: confidence,
                    verdictSource: verdict.source,
                    confirmedAt: verdict.confirmedAt
                )
                candidates.append(candidate)
                trace.append(
                    "• \(concept.id) [\(concept.kind.rawValue)] → \(rule.verdict.rawValue) " +
                    "(\(Int(confidence * 100))% via \(verdict.source.rawValue), rule \(rule.id))"
                )
            }
        }

        // CRITICAL: filter by confidence threshold BEFORE applying the severity
        // ladder. Otherwise a low-confidence high-severity verdict (e.g.
        // AI-returned `watchlist 0.55`) would "win" over a high-confidence
        // benign rule (e.g. `vendor:apple` benign 0.95), only to be rejected
        // immediately for being below threshold — leaving the cluster
        // unclassified despite having a perfectly good benign verdict.
        let viable = candidates.filter { $0.confidence >= Self.gatingThreshold }

        guard let winner = pickWinner(from: viable) else {
            // No candidate meets the gate. Surface unclassified, but record
            // the best below-threshold candidate so the trace explains why.
            if let bestBelow = pickWinner(from: candidates) {
                trace.append("→ best candidate \(bestBelow.conceptID) → \(bestBelow.verdict.rawValue) " +
                             "(\(Int(bestBelow.confidence * 100))%) below " +
                             "\(Int(Self.gatingThreshold * 100))% threshold")
                return ResolvedVerdict(
                    outcome: .unclassified(linkedConceptIDs: concepts.map(\.id)),
                    winningConceptID: bestBelow.conceptID,
                    winningRuleID: bestBelow.rule.id,
                    trace: trace
                )
            }
            return ResolvedVerdict(
                outcome: .unclassified(linkedConceptIDs: unclassifiedConceptIDs.isEmpty
                                       ? concepts.map(\.id)
                                       : unclassifiedConceptIDs),
                winningConceptID: nil,
                winningRuleID: nil,
                trace: trace
            )
        }

        trace.append("→ winner: \(winner.conceptID) → \(winner.verdict.rawValue) (\(Int(winner.confidence * 100))%)")
        return ResolvedVerdict(
            outcome: .classified(verdict: winner.verdict, confidence: winner.confidence),
            winningConceptID: winner.conceptID,
            winningRuleID: winner.rule.id,
            trace: trace
        )
    }

    /// Convenience that fetches the linked concepts itself (off-the-fly DB read
    /// — only call from background threads or when caching the concept list).
    func resolveByFingerprint(item: PersistenceItem, fingerprintHash: String) -> ResolvedVerdict {
        let ids = (try? conceptStore.conceptIDs(for: fingerprintHash)) ?? []
        return resolve(item: item, linkedConceptIDs: ids)
    }

    // MARK: - Verdict ladder

    private struct Candidate {
        let conceptID: String
        let conceptKind: ConceptKind
        let rule: KnowledgeRule
        let verdict: KnowledgeVerdict
        let confidence: Double
        let verdictSource: ConceptVerdictSource
        let confirmedAt: Date
    }

    private func pickWinner(from candidates: [Candidate]) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            // Returns true iff lhs is "less than" rhs, so .max gives us the
            // strongest candidate. We compose comparisons in the ladder order.
            if lhs.verdict.severity != rhs.verdict.severity {
                return lhs.verdict.severity < rhs.verdict.severity
            }
            if abs(lhs.confidence - rhs.confidence) > 0.01 {
                return lhs.confidence < rhs.confidence
            }
            let lhsSpec = specificity(for: lhs)
            let rhsSpec = specificity(for: rhs)
            if lhsSpec != rhsSpec {
                return lhsSpec < rhsSpec
            }
            let lhsSource = sourceWeight(lhs.verdictSource)
            let rhsSource = sourceWeight(rhs.verdictSource)
            if lhsSource != rhsSource {
                return lhsSource < rhsSource
            }
            return lhs.confirmedAt < rhs.confirmedAt
        }
    }

    private func specificity(for candidate: Candidate) -> Int {
        // Kind weight + length tie-breaker so longer concept IDs (more
        // specific) win within the same kind.
        return candidate.conceptKind.specificity * 100 + min(candidate.conceptID.count, 99)
    }

    private func sourceWeight(_ source: ConceptVerdictSource) -> Int {
        switch source {
        case .userDefined:     return 4
        case .aiExtracted:     return 3
        case .clusterAI:       return 2
        case .seedKnownVendor: return 1
        }
    }

    // MARK: - Snapshot caches
    //
    // The resolver is called once per filtered item — easily 6800+ times in a
    // single filter pass. Going to the DB on every call is unworkable, so we
    // hold short-lived in-memory snapshots of all rules and all verdicts and
    // refresh them lazily (5s TTL) or on explicit `invalidate()`.

    private let cacheLock = NSLock()
    private let cacheTTL: TimeInterval = 5

    private var cachedRulesByID: [String: KnowledgeRule] = [:]
    private var rulesLoadedAt: Date?

    private var cachedVerdictsByConcept: [String: [ConceptVerdict]] = [:]
    private var verdictsLoadedAt: Date?

    private func loadRulesByIDCached() -> [String: KnowledgeRule] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let last = rulesLoadedAt, Date().timeIntervalSince(last) < cacheTTL {
            return cachedRulesByID
        }
        let rules = (try? ruleStore.allRules()) ?? []
        let mapped = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
        cachedRulesByID = mapped
        rulesLoadedAt = Date()
        return mapped
    }

    private func loadAllVerdictsCached() -> [String: [ConceptVerdict]] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let last = verdictsLoadedAt, Date().timeIntervalSince(last) < cacheTTL {
            return cachedVerdictsByConcept
        }
        let all: [ConceptVerdict]
        if let dbQueue = DatabaseManager.shared.dbQueue {
            all = (try? dbQueue.read { db in try ConceptVerdict.fetchAll(db) }) ?? []
        } else {
            all = []
        }
        let grouped = Dictionary(grouping: all, by: { $0.conceptID })
        cachedVerdictsByConcept = grouped
        verdictsLoadedAt = Date()
        return grouped
    }

    /// Forces the next resolution to refresh from disk. Call after concept
    /// graph mutations (verdict attachment, rule changes).
    func invalidate() {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cachedRulesByID.removeAll()
        rulesLoadedAt = nil
        cachedVerdictsByConcept.removeAll()
        verdictsLoadedAt = nil
    }
}

// MARK: - Severity ordering for KnowledgeVerdict

extension KnowledgeVerdict {
    /// Higher = "more dangerous". Drives the verdict ladder: malicious wins
    /// over watchlist wins over benign.
    var severity: Int {
        switch self {
        case .benign:    return 0
        case .watchlist: return 1
        case .malicious: return 2
        }
    }
}
