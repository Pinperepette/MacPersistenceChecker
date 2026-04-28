import Foundation

/// Sends a batch of `ConceptCluster`s to Claude in a single call and propagates
/// each returned verdict to a concept (creating a `ConceptVerdict` and the
/// underlying `KnowledgeRule` so the resolver picks it up immediately).
///
/// Splits into batches of `maxClustersPerCall` so the prompt stays
/// manageable for Haiku (~10-20 clusters per call).
@MainActor
final class ClusterBatchAnalyst {
    static let shared = ClusterBatchAnalyst()

    private let configuration = AIConfiguration.shared
    private let apiClient = ClaudeAPIClient()
    private let conceptStore = ConceptStore.shared
    private let ruleStore = KnowledgeGraphStore.shared
    private let resolver = ConceptResolver.shared

    /// Cap clusters per API call. Each cluster takes ~150-300 tokens of prompt
    /// space (signature + sample items). 15 fits safely under model context.
    let maxClustersPerCall: Int = 15

    private init() {}

    // MARK: - Errors

    enum BatchError: Error, LocalizedError {
        case aiNotAvailable
        case dailyCapReached(remaining: Int)
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .aiNotAvailable:
                return "AI is disabled or the API key is missing."
            case .dailyCapReached:
                return "Daily AI call cap reached."
            case .underlying(let err):
                return err.localizedDescription
            }
        }
    }

    // MARK: - Response schema

    struct BatchResponse: Codable {
        let clusters: [ClusterVerdict]
    }

    struct ClusterVerdict: Codable {
        let id: String
        let verdict: String
        let confidence: Double?
        let attachToConcept: String
        let rationale: String?
    }

    // MARK: - Public

    struct BatchOutcome {
        let processedClusterIDs: [String]
        let failedClusterIDs: [String]
        let appliedVerdicts: Int
        let apiCallsMade: Int
    }

    /// Runs the batch analyst over the given clusters. Returns when all calls
    /// finish or the cap is hit.
    ///
    /// Skips clusters that AI has already analyzed (regardless of the
    /// confidence the AI returned). Without this filter, a cluster whose AI
    /// verdict was below the resolver gate would re-enter the working set
    /// every refresh and the user would have to keep pressing the button —
    /// burning the daily budget on the same clusters over and over.
    func analyze(clusters: [ConceptCluster]) async throws -> BatchOutcome {
        guard configuration.isAIActive else { throw BatchError.aiNotAvailable }
        let workingSet = clusters.filter { $0.needsClassification && !$0.aiAnalyzed }
        guard !workingSet.isEmpty else {
            return BatchOutcome(processedClusterIDs: [], failedClusterIDs: [], appliedVerdicts: 0, apiCallsMade: 0)
        }

        var processed: [String] = []
        var failed: [String] = []
        var applied = 0
        var calls = 0

        // Slice into manageable batches.
        for batch in workingSet.chunked(into: maxClustersPerCall) {
            guard configuration.canMakeCall else {
                throw BatchError.dailyCapReached(remaining: configuration.callsRemainingToday)
            }

            do {
                let response = try await runBatch(batch)
                configuration.recordCall()
                calls += 1
                // DB writes (insert rule + attach verdict) run off main so the
                // app stays responsive while a long batch propagates verdicts.
                let appliedHere = await applyVerdicts(response.clusters, sourceClusters: batch)
                applied += appliedHere
                processed.append(contentsOf: response.clusters.map(\.id))

                let returnedIDs = Set(response.clusters.map(\.id))
                let missing = batch.filter { !returnedIDs.contains($0.id) }.map(\.id)
                failed.append(contentsOf: missing)
            } catch {
                NSLog("[ClusterBatchAnalyst] batch failed: %@", error.localizedDescription)
                configuration.recordCall()           // we still hit the API
                calls += 1
                failed.append(contentsOf: batch.map(\.id))
            }
        }

        // Refresh resolver caches so the new verdicts surface immediately.
        resolver.invalidate()

        return BatchOutcome(
            processedClusterIDs: processed,
            failedClusterIDs: failed,
            appliedVerdicts: applied,
            apiCallsMade: calls
        )
    }

    // MARK: - One call

    private func runBatch(_ clusters: [ConceptCluster]) async throws -> BatchResponse {
        let userJSON = encodeBatchUserPayload(clusters)
        let systemPrompt = PromptLoader.load(.clusterAnalyst)

        let raw = try await apiClient.chatRaw(
            systemPrompt: systemPrompt,
            userJSON: userJSON,
            model: configuration.haikuModel,
            maxTokens: 3500
        )
        return try apiClient.decodeJSON(BatchResponse.self, from: raw)
    }

    /// Builds the prompt input — clusters with their concept signature and
    /// up to 5 sample items each.
    private func encodeBatchUserPayload(_ clusters: [ConceptCluster]) -> String {
        struct Sample: Codable {
            let name: String
            let identifier: String
            let category: String
            let executablePath: String?
            let plistPath: String?
            let signed: Bool
            let signatureValid: Bool
            let appleSigned: Bool
            let teamID: String?
        }

        struct ClusterPayload: Codable {
            let id: String
            let conceptIDs: [String]
            let memberCount: Int
            let displayLabel: String
            let samples: [Sample]
        }

        let payloads = clusters.map { cluster in
            ClusterPayload(
                id: cluster.id,
                conceptIDs: cluster.conceptIDs,
                memberCount: cluster.memberItems.count,
                displayLabel: cluster.displayLabel,
                samples: cluster.sampleItems.prefix(5).map { item in
                    Sample(
                        name: item.name,
                        identifier: item.identifier,
                        category: item.category.rawValue,
                        executablePath: item.executablePath?.path,
                        plistPath: item.plistPath?.path,
                        signed: item.signatureInfo?.isSigned ?? false,
                        signatureValid: item.signatureInfo?.isValid ?? false,
                        appleSigned: item.signatureInfo?.isAppleSigned ?? false,
                        teamID: item.signatureInfo?.teamIdentifier
                    )
                }
            )
        }

        if let data = try? JSONEncoder().encode(["clusters": payloads]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"clusters\": []}"
    }

    // MARK: - Verdict application

    /// Persist each verdict as: a knowledgeRule (predicate carrying the
    /// concept ID) + a concept_verdict row linking the rule to the chosen
    /// concept. The rule is a single-clause `userDefined`-shaped predicate
    /// using `categoryEquals` (a stable anchor) so it survives existing
    /// matcher logic.
    /// Persists each verdict off the main thread (Task.detached) so the UI
    /// stays responsive even when the AI returns dozens of cluster verdicts
    /// per batch (each verdict = 2 SQL writes).
    private func applyVerdicts(
        _ verdicts: [ClusterVerdict],
        sourceClusters: [ConceptCluster]
    ) async -> Int {
        let bySignature = Dictionary(uniqueKeysWithValues: sourceClusters.map { ($0.id, $0) })
        let conceptStoreRef = conceptStore
        let ruleStoreRef = ruleStore
        let now = Date()

        return await Task.detached(priority: .userInitiated) {
            var applied = 0
            for verdictResp in verdicts {
                guard let cluster = bySignature[verdictResp.id] else { continue }
                guard let knowledgeVerdict = KnowledgeVerdict(rawValue: verdictResp.verdict) else { continue }

                // Concept must exist; if AI invented one, skip.
                guard let concept = conceptStoreRef.cachedConcept(id: verdictResp.attachToConcept) else {
                    NSLog("[ClusterBatchAnalyst] AI proposed unknown concept '%@' for cluster %@",
                          verdictResp.attachToConcept, verdictResp.id)
                    continue
                }

                // Rule predicate is symbolic — its real role is to be uniquely
                // identifiable; the actual matching happens via the concept layer.
                let predicate = RulePredicate(clauses: [
                    .categoryEquals("__concept__:\(concept.id)")
                ])
                let rule = KnowledgeRule(
                    id: UUID().uuidString,
                    source: .aiExtracted,
                    scope: .singleItem,
                    verdict: knowledgeVerdict,
                    predicate: predicate,
                    confidence: max(0.5, min(1.0, verdictResp.confidence ?? 0.85)),
                    occurrences: cluster.memberItems.count,
                    sourceItems: cluster.memberFingerprints,
                    rationale: verdictResp.rationale ?? "Cluster verdict from AI batch",
                    createdAt: now,
                    lastConfirmedAt: now,
                    disabled: false
                )

                do {
                    try ruleStoreRef.insertRule(rule)
                    let verdictRecord = ConceptVerdict(
                        id: UUID().uuidString,
                        conceptID: concept.id,
                        ruleID: rule.id,
                        source: .clusterAI,
                        weight: 1.0,
                        createdAt: now,
                        confirmedAt: now
                    )
                    try conceptStoreRef.attachVerdict(verdictRecord)
                    applied += 1
                } catch {
                    NSLog("[ClusterBatchAnalyst] failed to persist verdict for %@: %@",
                          concept.id, error.localizedDescription)
                }
            }
            return applied
        }.value
    }
}

// MARK: - Array chunking

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
