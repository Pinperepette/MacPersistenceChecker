import Foundation
import GRDB

/// Thread-safe store for the knowledge graph (rules + fingerprints).
///
/// Wraps the existing `DatabaseManager` GRDB queue. All disk I/O happens off the
/// main thread because GRDB's `dbQueue.read/write` block on the queue's own thread.
/// We keep this as a `final class` (not `actor`) because the underlying queue is
/// already thread-safe; an actor would add a redundant hop.
final class KnowledgeGraphStore {
    static let shared = KnowledgeGraphStore()

    private var dbQueue: DatabaseQueue? {
        DatabaseManager.shared.dbQueue
    }

    private init() {}

    // MARK: - Rules

    /// Insert a new rule. Caller is responsible for validation (see RuleValidator).
    func insertRule(_ rule: KnowledgeRule) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        try dbQueue.write { db in
            try rule.insert(db)
        }
        RuleMatcher.shared.invalidate()
    }

    /// Update confidence/occurrences/lastConfirmedAt on an existing rule.
    func confirmRule(id: String, atDate date: Date = Date()) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE knowledgeRules
                SET occurrences = occurrences + 1,
                    lastConfirmedAt = ?,
                    confidence = MIN(1.0, confidence + 0.05)
                WHERE id = ?
                """, arguments: [date.timeIntervalSince1970, id])
        }
        RuleMatcher.shared.invalidate()
    }

    /// Fetch all enabled rules.
    func enabledRules() throws -> [KnowledgeRule] {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        return try dbQueue.read { db in
            try KnowledgeRule
                .filter(KnowledgeRule.Columns.disabled == false)
                .fetchAll(db)
        }
    }

    /// Fetch all rules (incl. disabled) — for management UI.
    func allRules() throws -> [KnowledgeRule] {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        return try dbQueue.read { db in
            try KnowledgeRule.fetchAll(db)
        }
    }

    func deleteRule(id: String) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        _ = try dbQueue.write { db in
            try KnowledgeRule.deleteOne(db, key: id)
        }
        RuleMatcher.shared.invalidate()
    }

    func setRuleDisabled(id: String, disabled: Bool) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE knowledgeRules SET disabled = ? WHERE id = ?",
                arguments: [disabled, id]
            )
        }
        RuleMatcher.shared.invalidate()
    }

    // MARK: - Fingerprints

    /// Record that we observed a fingerprint. Inserts on first sight, increments otherwise.
    /// Returns the resulting record (with current occurrences/lastSeenAt).
    ///
    /// Implementation note: the table uses an autoincrement `rowId` PK that
    /// `FingerprintRecord` doesn't carry as a field, so GRDB's `.update()`
    /// would fail with `RecordError.recordNotFound`. We use raw SQL keyed on
    /// the unique `fingerprintHash` column instead.
    @discardableResult
    func recordSighting(_ fingerprint: ItemFingerprint, matchedRuleId: String? = nil) throws -> FingerprintRecord {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        let hash = fingerprint.hash
        let now = Date()

        return try dbQueue.write { db in
            let exists = try FingerprintRecord
                .filter(FingerprintRecord.Columns.fingerprintHash == hash)
                .fetchOne(db) != nil
            if exists {
                try db.execute(
                    sql: """
                    UPDATE knowledgeFingerprints
                    SET lastSeenAt = ?,
                        occurrences = occurrences + 1,
                        matchedRuleId = COALESCE(?, matchedRuleId)
                    WHERE fingerprintHash = ?
                    """,
                    arguments: [now.timeIntervalSince1970, matchedRuleId, hash]
                )
                if let refreshed = try FingerprintRecord
                    .filter(FingerprintRecord.Columns.fingerprintHash == hash)
                    .fetchOne(db) {
                    return refreshed
                }
                // Should never happen — fall through to insert as a safety net.
            }

            let record = FingerprintRecord(
                fingerprintHash: hash,
                teamID: fingerprint.teamID,
                pathNormalized: fingerprint.pathNormalized,
                bundleIdentifier: fingerprint.bundleIdentifier,
                category: fingerprint.category,
                firstSeenAt: now,
                lastSeenAt: now,
                matchedRuleId: matchedRuleId,
                occurrences: 1
            )
            try record.insert(db)
            return record
        }
    }

    func fingerprint(forHash hash: String) throws -> FingerprintRecord? {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        return try dbQueue.read { db in
            try FingerprintRecord
                .filter(FingerprintRecord.Columns.fingerprintHash == hash)
                .fetchOne(db)
        }
    }
}
