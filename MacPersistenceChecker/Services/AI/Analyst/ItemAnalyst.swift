import Foundation

/// On-demand AI analyst for a single PersistenceItem.
///
/// Sends a structured request to Claude Haiku and expects a verdict + an
/// optional generalizable rule (predicate over signed identity). The extracted
/// rule is validated and persisted to the knowledge graph so future similar
/// items short-circuit at the L1 layer (no API call).
@MainActor
final class ItemAnalyst {
    static let shared = ItemAnalyst()

    private let configuration = AIConfiguration.shared
    private let apiClient = ClaudeAPIClient()
    private let store = KnowledgeGraphStore.shared

    private init() {}

    // MARK: - Errors

    enum AnalystError: Error, LocalizedError {
        case aiNotAvailable
        case dailyCapReached(remaining: Int)
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .aiNotAvailable:
                return "AI is disabled or the API key is missing."
            case .dailyCapReached:
                return "Daily AI call cap reached. Increase the cap in settings or try again tomorrow."
            case .underlying(let err):
                return err.localizedDescription
            }
        }
    }

    // MARK: - Slim request payload (sent to Claude)

    /// Neutral facts about the item — no pre-computed risk signals.
    /// We deliberately omit riskScore, signedButDangerousFlags, lolbinsDetections,
    /// behavioralAnomalies, intentMismatches, ageAnomalies. Those are local
    /// heuristics; sending them biases the model into rubber-stamping our flags
    /// instead of judging the raw facts.
    struct AnalystPayload: Codable {
        struct Signature: Codable {
            let isSigned: Bool
            let isValid: Bool
            let isAppleSigned: Bool
            let isNotarized: Bool
            let hasHardenedRuntime: Bool
            let teamIdentifier: String?
            let organizationName: String?
            let commonName: String?
            let signingAuthority: String?
        }

        struct SystemInfo: Codable {
            let hostname: String
            let macosVersion: String
        }

        let identifier: String
        let name: String
        let category: String
        let bundleIdentifier: String?
        let plistPath: String?
        let executablePath: String?
        let parentAppPath: String?
        let workingDirectory: String?
        let isEnabled: Bool
        let isLoaded: Bool

        let programArguments: [String]?
        let runAtLoad: Bool?
        let keepAlive: Bool?
        let environmentVariables: [String: String]?

        let signature: Signature?

        let plistCreatedAt: String?
        let plistModifiedAt: String?
        let binaryCreatedAt: String?
        let binaryModifiedAt: String?
        let discoveredAt: String

        let systemInfo: SystemInfo

        static func make(from item: PersistenceItem) -> AnalystPayload {
            let iso = ISO8601DateFormatter()
            var sig: Signature? = nil
            if let s = item.signatureInfo {
                sig = Signature(
                    isSigned: s.isSigned,
                    isValid: s.isValid,
                    isAppleSigned: s.isAppleSigned,
                    isNotarized: s.isNotarized,
                    hasHardenedRuntime: s.hasHardenedRuntime,
                    teamIdentifier: s.teamIdentifier,
                    organizationName: s.organizationName,
                    commonName: s.commonName,
                    signingAuthority: s.signingAuthority
                )
            }
            return AnalystPayload(
                identifier: item.identifier,
                name: item.name,
                category: item.category.rawValue,
                bundleIdentifier: item.bundleIdentifier,
                plistPath: item.plistPath?.path,
                executablePath: item.executablePath?.path,
                parentAppPath: item.parentAppPath?.path,
                workingDirectory: item.workingDirectory,
                isEnabled: item.isEnabled,
                isLoaded: item.isLoaded,
                programArguments: item.programArguments,
                runAtLoad: item.runAtLoad,
                keepAlive: item.keepAlive,
                environmentVariables: item.environmentVariables,
                signature: sig,
                plistCreatedAt: item.plistCreatedAt.map { iso.string(from: $0) },
                plistModifiedAt: item.plistModifiedAt.map { iso.string(from: $0) },
                binaryCreatedAt: item.binaryCreatedAt.map { iso.string(from: $0) },
                binaryModifiedAt: item.binaryModifiedAt.map { iso.string(from: $0) },
                discoveredAt: iso.string(from: item.discoveredAt),
                systemInfo: SystemInfo(
                    hostname: Host.current().localizedName ?? "Unknown",
                    macosVersion: ProcessInfo.processInfo.operatingSystemVersionString
                )
            )
        }
    }

    // MARK: - Response schema

    /// What Claude is instructed to return. Mirrors RulePredicate.Clause but as a
    /// flat JSON object so the model has a clearer target.
    ///
    /// `value` is decoded permissively — Claude sometimes emits booleans or
    /// numbers where we expect a string (e.g. `{"kind":"isNotarized","value":true}`).
    /// Rather than failing the whole parse, we coerce to String. The unknown
    /// kind is then filtered out by `mapClause`.
    struct ExtractedClause: Codable {
        let kind: String
        let value: String?

        private enum CodingKeys: String, CodingKey { case kind, value }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = try c.decode(String.self, forKey: .kind)
            if let s = try? c.decode(String.self, forKey: .value) {
                self.value = s
            } else if let b = try? c.decode(Bool.self, forKey: .value) {
                self.value = b ? "true" : "false"
            } else if let i = try? c.decode(Int.self, forKey: .value) {
                self.value = String(i)
            } else if let d = try? c.decode(Double.self, forKey: .value) {
                self.value = String(d)
            } else {
                self.value = nil
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(value, forKey: .value)
        }
    }

    struct ExtractedRule: Codable {
        let scope: String   // "singleItem" | "pattern"
        let clauses: [ExtractedClause]
        let rationale: String?
    }

    struct AnalystResponse: Codable {
        let verdict: String        // "benign" | "watchlist" | "malicious"
        let confidence: Double
        let explanation: String
        let mitreTechniques: [String]?
        let extractedRule: ExtractedRule?
    }

    /// What we surface to the UI after persisting the result.
    struct AnalysisOutcome {
        let verdict: KnowledgeVerdict
        let confidence: Double
        let explanation: String
        let mitreTechniques: [String]
        let savedRuleID: String?
        let ruleScope: RuleScope?
    }

    // MARK: - Public entry

    func analyze(item: PersistenceItem) async throws -> AnalysisOutcome {
        guard configuration.isAIActive else { throw AnalystError.aiNotAvailable }
        guard configuration.canMakeCall else {
            throw AnalystError.dailyCapReached(remaining: configuration.callsRemainingToday)
        }

        let payload = AnalystPayload.make(from: item)
        let userJSON: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            userJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw AnalystError.underlying(error)
        }

        let basePrompt = PromptLoader.load(.itemAnalyst)
        let systemPrompt: String
        let extra = configuration.fullAnalysisPrompt
        if extra.isEmpty {
            systemPrompt = basePrompt
        } else {
            systemPrompt = basePrompt + "\n\n## User-configured preferences\n" + extra
        }

        let rawText: String
        do {
            rawText = try await apiClient.chatRaw(
                systemPrompt: systemPrompt,
                userJSON: userJSON,
                model: configuration.haikuModel,
                maxTokens: 2048
            )
        } catch {
            throw AnalystError.underlying(error)
        }

        // Count the call regardless of parse outcome — the API was hit.
        configuration.recordCall()

        let response: AnalystResponse
        do {
            response = try apiClient.decodeJSON(AnalystResponse.self, from: rawText)
        } catch {
            throw AnalystError.underlying(error)
        }

        let verdict = KnowledgeVerdict(rawValue: response.verdict) ?? .watchlist
        let outcome = try persist(item: item, response: response, verdict: verdict)
        RuleMatcher.shared.invalidate()
        return outcome
    }

    // MARK: - Persistence

    private func persist(
        item: PersistenceItem,
        response: AnalystResponse,
        verdict: KnowledgeVerdict
    ) throws -> AnalysisOutcome {
        let fingerprint = ItemFingerprint.make(from: item)
        var savedRuleID: String?
        var savedScope: RuleScope?

        if let extracted = response.extractedRule, !extracted.clauses.isEmpty {
            let predicate = RulePredicate(
                clauses: extracted.clauses.compactMap(Self.mapClause)
            )
            if !predicate.clauses.isEmpty {
                let scope: RuleScope = extracted.scope == "pattern" ? .pattern : .singleItem
                let candidate = KnowledgeRule(
                    id: UUID().uuidString,
                    source: .aiExtracted,
                    scope: scope,
                    verdict: verdict,
                    predicate: predicate,
                    confidence: max(0.5, min(1.0, response.confidence)),
                    occurrences: 1,
                    sourceItems: [fingerprint.hash],
                    rationale: extracted.rationale ?? response.explanation,
                    createdAt: Date(),
                    lastConfirmedAt: Date(),
                    disabled: false
                )

                do {
                    let validated = try RuleValidator.validate(candidate)
                    try store.insertRule(validated)
                    savedRuleID = validated.id
                    savedScope = validated.scope
                } catch {
                    // Rule validation can fail for very thin predicates;
                    // we fall back below so the verdict is still persisted.
                    NSLog("[ItemAnalyst] Rule validation failed: %@", error.localizedDescription)
                }
            }
        }

        // Fallback: if the AI didn't produce a usable rule (null, empty, or
        // composed entirely of unsupported clause kinds), persist the verdict
        // anyway as a singleItem rule anchored to this fingerprint. Without
        // this, the user sees a verdict in the bulk view but the main list
        // never updates because there's nothing in the graph to match.
        if savedRuleID == nil {
            let identifier = item.bundleIdentifier ?? item.identifier
            let fallback = KnowledgeRule(
                id: UUID().uuidString,
                source: .aiExtracted,
                scope: .singleItem,
                verdict: verdict,
                predicate: RulePredicate(clauses: [.bundleIDEquals(identifier)]),
                confidence: max(0.5, min(1.0, response.confidence)),
                occurrences: 1,
                sourceItems: [fingerprint.hash],
                rationale: response.explanation,
                createdAt: Date(),
                lastConfirmedAt: Date(),
                disabled: false
            )
            do {
                let validated = try RuleValidator.validate(fallback)
                try store.insertRule(validated)
                savedRuleID = validated.id
                savedScope = validated.scope
            } catch {
                NSLog("[ItemAnalyst] Fallback rule save failed: %@", error.localizedDescription)
            }
        }

        _ = try? store.recordSighting(fingerprint, matchedRuleId: savedRuleID)

        return AnalysisOutcome(
            verdict: verdict,
            confidence: response.confidence,
            explanation: response.explanation,
            mitreTechniques: response.mitreTechniques ?? [],
            savedRuleID: savedRuleID,
            ruleScope: savedScope
        )
    }

    // MARK: - Clause mapping

    private static func mapClause(_ clause: ExtractedClause) -> RulePredicate.Clause? {
        switch clause.kind {
        case "teamIDEquals":
            guard let v = clause.value, !v.isEmpty else { return nil }
            return .teamIDEquals(v)
        case "bundleIDEquals":
            guard let v = clause.value, !v.isEmpty else { return nil }
            return .bundleIDEquals(v)
        case "bundleIDPrefix":
            guard let v = clause.value, !v.isEmpty else { return nil }
            return .bundleIDPrefix(v)
        case "pathEquals":
            guard let v = clause.value, !v.isEmpty else { return nil }
            return .pathEquals(v)
        case "pathPrefix":
            guard let v = clause.value, !v.isEmpty else { return nil }
            return .pathPrefix(v)
        case "categoryEquals":
            guard let v = clause.value, !v.isEmpty else { return nil }
            return .categoryEquals(v)
        case "signatureValid":
            return .signatureValid
        case "appleSigned":
            return .appleSigned
        default:
            return nil
        }
    }

}
