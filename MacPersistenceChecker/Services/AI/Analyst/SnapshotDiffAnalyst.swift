import Foundation

/// Compares two persistence snapshots and produces a narrative diff via Haiku.
/// Different from the live monitor: this is a deliberate "review what changed
/// since last week" workflow, run on demand, on user-selected snapshot pairs.
@MainActor
final class SnapshotDiffAnalyst {
    static let shared = SnapshotDiffAnalyst()

    private let configuration = AIConfiguration.shared
    private let apiClient = ClaudeAPIClient()

    private init() {}

    enum DiffError: Error, LocalizedError {
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

    struct DiffResult: Codable {
        let summary: String
        let added: [Entry]
        let removed: [Entry]
        let modified: [Entry]
    }

    struct Entry: Codable, Identifiable {
        let name: String
        let explanation: String
        var id: String { name }
    }

    // MARK: - Public

    /// Diff two snapshots (older → newer) and ask Haiku for a narrative.
    func analyze(olderSnapshotID: UUID, newerSnapshotID: UUID) async throws -> DiffResult {
        guard configuration.isAIActive else { throw DiffError.aiNotAvailable }
        guard configuration.canMakeCall else { throw DiffError.dailyCapReached }

        let payloadJSON: String = try await Task.detached(priority: .userInitiated) {
            try Self.buildPayload(older: olderSnapshotID, newer: newerSnapshotID)
        }.value

        let systemPrompt = PromptLoader.load(.snapshotDiff)
        do {
            let raw = try await apiClient.chatRaw(
                systemPrompt: systemPrompt,
                userJSON: payloadJSON,
                model: configuration.haikuModel,
                maxTokens: 1500
            )
            configuration.recordCall()
            return try apiClient.decodeJSON(DiffResult.self, from: raw)
        } catch {
            configuration.recordCall()
            throw DiffError.underlying(error)
        }
    }

    // MARK: - Payload

    /// Loads both snapshots' items, computes diff, returns the JSON string
    /// to send to Haiku. Off-main.
    private nonisolated static func buildPayload(older: UUID, newer: UUID) throws -> String {
        let dbm = DatabaseManager.shared
        let olderItems = try dbm.getItems(for: older)
        let newerItems = try dbm.getItems(for: newer)

        let olderByID = Dictionary(uniqueKeysWithValues: olderItems.map { ($0.identifier, $0) })
        let newerByID = Dictionary(uniqueKeysWithValues: newerItems.map { ($0.identifier, $0) })

        let olderIDs = Set(olderByID.keys)
        let newerIDs = Set(newerByID.keys)

        let addedIDs = newerIDs.subtracting(olderIDs)
        let removedIDs = olderIDs.subtracting(newerIDs)
        let commonIDs = olderIDs.intersection(newerIDs)

        var added: [ItemSummary] = addedIDs.compactMap { id in
            guard let item = newerByID[id] else { return nil }
            return ItemSummary.make(from: item)
        }
        var removed: [ItemSummary] = removedIDs.compactMap { id in
            guard let item = olderByID[id] else { return nil }
            return ItemSummary.make(from: item)
        }
        var modified: [ModifiedSummary] = []
        for id in commonIDs {
            guard let oldItem = olderByID[id], let newItem = newerByID[id] else { continue }
            let changes = detectChanges(old: oldItem, new: newItem)
            if !changes.isEmpty {
                modified.append(ModifiedSummary(
                    summary: ItemSummary.make(from: newItem),
                    changes: changes
                ))
            }
        }

        // Cap each list at 30 to keep the prompt size reasonable. AI is told
        // to summarize groups when needed.
        added = Array(added.prefix(30))
        removed = Array(removed.prefix(30))
        modified = Array(modified.prefix(30))

        let payload = DiffPayload(
            olderSnapshot: SnapshotInfo(id: older.uuidString, itemCount: olderItems.count),
            newerSnapshot: SnapshotInfo(id: newer.uuidString, itemCount: newerItems.count),
            addedCount: addedIDs.count,
            removedCount: removedIDs.count,
            modifiedCount: modified.count,
            added: added,
            removed: removed,
            modified: modified
        )

        let data = try JSONEncoder().encode(payload)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Helpers

    private nonisolated static func detectChanges(old: PersistenceItem, new: PersistenceItem) -> [String] {
        var changes: [String] = []
        if old.trustLevel != new.trustLevel {
            changes.append("trustLevel: \(old.trustLevel.rawValue) → \(new.trustLevel.rawValue)")
        }
        if old.isEnabled != new.isEnabled {
            changes.append("enabled: \(old.isEnabled) → \(new.isEnabled)")
        }
        if old.executablePath?.path != new.executablePath?.path {
            changes.append("executablePath changed")
        }
        if old.signatureInfo?.teamIdentifier != new.signatureInfo?.teamIdentifier {
            changes.append("teamID changed")
        }
        if old.signatureInfo?.isValid != new.signatureInfo?.isValid {
            changes.append("signature validity changed")
        }
        if old.binaryModifiedAt != new.binaryModifiedAt {
            changes.append("binary re-modified")
        }
        return changes
    }

    // MARK: - Payload types

    private struct DiffPayload: Codable {
        let olderSnapshot: SnapshotInfo
        let newerSnapshot: SnapshotInfo
        let addedCount: Int
        let removedCount: Int
        let modifiedCount: Int
        let added: [ItemSummary]
        let removed: [ItemSummary]
        let modified: [ModifiedSummary]
    }

    private struct SnapshotInfo: Codable {
        let id: String
        let itemCount: Int
    }

    private struct ItemSummary: Codable {
        let name: String
        let identifier: String
        let category: String
        let executablePath: String?
        let plistPath: String?
        let teamID: String?
        let organization: String?
        let appleSigned: Bool

        static func make(from item: PersistenceItem) -> ItemSummary {
            ItemSummary(
                name: item.name,
                identifier: item.identifier,
                category: item.category.rawValue,
                executablePath: item.executablePath?.path,
                plistPath: item.plistPath?.path,
                teamID: item.signatureInfo?.teamIdentifier,
                organization: item.signatureInfo?.organizationName,
                appleSigned: item.signatureInfo?.isAppleSigned ?? false
            )
        }
    }

    private struct ModifiedSummary: Codable {
        let summary: ItemSummary
        let changes: [String]
    }
}
