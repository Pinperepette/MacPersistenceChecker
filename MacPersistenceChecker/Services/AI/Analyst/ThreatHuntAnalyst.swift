import Foundation

/// Natural-language Q&A against the current persistence inventory.
/// User types a question, AI returns matching items + rationale.
@MainActor
final class ThreatHuntAnalyst {
    static let shared = ThreatHuntAnalyst()

    private let configuration = AIConfiguration.shared
    private let apiClient = ClaudeAPIClient()

    private init() {}

    enum HuntError: Error, LocalizedError {
        case aiNotAvailable
        case dailyCapReached
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .aiNotAvailable: return "AI is disabled or the API key is missing."
            case .dailyCapReached: return "Daily AI call cap reached."
            case .underlying(let err): return err.localizedDescription
            }
        }
    }

    // MARK: - Response types

    struct HuntResult: Codable {
        let rationale: String
        let matchedItemIDs: [String]
        let perItemNotes: [ItemNote]
        let mitreTechniques: [String]?
    }

    struct ItemNote: Codable, Identifiable {
        let id: String
        let note: String
    }

    /// What the UI surfaces: the AI result joined back to actual
    /// PersistenceItem objects so the view can navigate / show details.
    struct ResolvedHuntResult {
        let rationale: String
        let matches: [(item: PersistenceItem, note: String)]
        let mitreTechniques: [String]
    }

    // MARK: - Public

    /// Run a hunt. Caller passes the items snapshot and the query.
    /// We cap the items sent to the AI so the prompt stays reasonable —
    /// for now we prioritize non-Apple items and high-risk items.
    func hunt(query: String, in items: [PersistenceItem]) async throws -> ResolvedHuntResult {
        guard configuration.isAIActive else { throw HuntError.aiNotAvailable }
        guard configuration.canMakeCall else { throw HuntError.dailyCapReached }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ResolvedHuntResult(rationale: "Empty query", matches: [], mitreTechniques: [])
        }

        let payloadJSON: String = await Task.detached(priority: .userInitiated) {
            ThreatHuntAnalyst.buildPayload(query: trimmed, items: items)
        }.value

        let systemPrompt = PromptLoader.load(.threatHunt)
        do {
            let raw = try await apiClient.chatRaw(
                systemPrompt: systemPrompt,
                userJSON: payloadJSON,
                model: configuration.haikuModel,
                maxTokens: 2000
            )
            configuration.recordCall()
            let result = try apiClient.decodeJSON(HuntResult.self, from: raw)
            return resolve(result: result, against: items)
        } catch {
            configuration.recordCall()
            throw HuntError.underlying(error)
        }
    }

    // MARK: - Helpers

    /// Joins AI output back to the actual items from the user's scan.
    private func resolve(result: HuntResult, against items: [PersistenceItem]) -> ResolvedHuntResult {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.identifier, $0) })
        let notes = Dictionary(uniqueKeysWithValues: result.perItemNotes.map { ($0.id, $0.note) })
        var matches: [(PersistenceItem, String)] = []
        for id in result.matchedItemIDs {
            guard let item = byID[id] else { continue }
            matches.append((item, notes[id] ?? ""))
        }
        return ResolvedHuntResult(
            rationale: result.rationale,
            matches: matches,
            mitreTechniques: result.mitreTechniques ?? []
        )
    }

    /// Picks at most 120 items to send to the AI: prioritize high risk,
    /// non-Apple, and items with interesting program arguments. Within
    /// budget, include a representative slice.
    private nonisolated static func buildPayload(query: String, items: [PersistenceItem]) -> String {
        let scored = items.map { item -> (PersistenceItem, Int) in
            var score = item.riskScore ?? 0
            // Boost non-Apple-signed items
            if item.signatureInfo?.isAppleSigned != true { score += 20 }
            // Boost items with arguments (more interesting for hunting)
            if item.programArguments?.isEmpty == false { score += 5 }
            // Boost items with launchctl loaded state
            if item.runAtLoad == true { score += 3 }
            if item.keepAlive == true { score += 3 }
            return (item, score)
        }
        let selected = scored
            .sorted { $0.1 > $1.1 }
            .prefix(120)
            .map { $0.0 }

        let summaries = selected.map { item -> ItemPayload in
            ItemPayload.make(from: item)
        }

        let payload = HuntPayload(
            query: query,
            totalItems: items.count,
            sampledCount: selected.count,
            items: summaries
        )

        if let data = try? JSONEncoder().encode(payload),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }

    // MARK: - Payload types

    private struct HuntPayload: Codable {
        let query: String
        let totalItems: Int
        let sampledCount: Int
        let items: [ItemPayload]
    }

    private struct ItemPayload: Codable {
        let id: String
        let name: String
        let category: String
        let executablePath: String?
        let plistPath: String?
        let programArguments: [String]?
        let runAtLoad: Bool?
        let keepAlive: Bool?
        let teamID: String?
        let organization: String?
        let appleSigned: Bool
        let signatureValid: Bool
        let trustLevel: String
        let riskScore: Int?

        static func make(from item: PersistenceItem) -> ItemPayload {
            ItemPayload(
                id: item.identifier,
                name: item.name,
                category: item.category.rawValue,
                executablePath: item.executablePath?.path,
                plistPath: item.plistPath?.path,
                programArguments: item.programArguments,
                runAtLoad: item.runAtLoad,
                keepAlive: item.keepAlive,
                teamID: item.signatureInfo?.teamIdentifier,
                organization: item.signatureInfo?.organizationName,
                appleSigned: item.signatureInfo?.isAppleSigned ?? false,
                signatureValid: item.signatureInfo?.isValid ?? false,
                trustLevel: item.trustLevel.rawValue,
                riskScore: item.riskScore
            )
        }
    }
}
