import Foundation
import GRDB

/// Persistence layer for the concept graph. All disk I/O happens off the main
/// thread (GRDB's queue serializes internally; callers wait on its dispatch
/// queue, not the UI). A small in-memory cache of all concepts is maintained
/// behind a lock so the resolver and visualizer can read snapshots fast.
final class ConceptStore: @unchecked Sendable {
    static let shared = ConceptStore()

    private var dbQueue: DatabaseQueue? { DatabaseManager.shared.dbQueue }

    // In-memory cache of concepts (id → Concept). Used by hot-path resolution.
    private let lock = NSLock()
    private var conceptCache: [String: Concept] = [:]
    private var loadedAtLeastOnce = false
    private var pendingTask: Task<Void, Never>?

    private init() {}

    // MARK: - Cache lifecycle

    /// Triggers a background reload of all concepts. Call at app launch and
    /// after a scan completes.
    func preload() {
        scheduleReload()
    }

    func invalidate() {
        scheduleReload()
    }

    private func scheduleReload() {
        let snapshot: () -> [Concept] = { [weak self] in
            (try? self?.fetchAllConceptsBlocking()) ?? []
        }
        lock.lock()
        pendingTask?.cancel()
        let task = Task.detached(priority: .utility) { [weak self] in
            let concepts = snapshot()
            guard let self else { return }
            self.lock.lock()
            self.conceptCache = Dictionary(uniqueKeysWithValues: concepts.map { ($0.id, $0) })
            self.loadedAtLeastOnce = true
            self.lock.unlock()
        }
        pendingTask = task
        lock.unlock()
    }

    // MARK: - Snapshots (memory)

    func cachedConcepts() -> [Concept] {
        lock.lock(); defer { lock.unlock() }
        return Array(conceptCache.values)
    }

    func cachedConcept(id: String) -> Concept? {
        lock.lock(); defer { lock.unlock() }
        return conceptCache[id]
    }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return loadedAtLeastOnce
    }

    // MARK: - Concepts CRUD

    /// Insert a concept if missing, or bump its `lastSeenAt`/`occurrences` if it
    /// already exists. Returns the resulting concept.
    @discardableResult
    func upsertConcept(_ concept: Concept) throws -> Concept {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        return try dbQueue.write { db in
            if var existing = try Concept.fetchOne(db, key: concept.id) {
                existing.occurrences += 1
                existing.lastSeenAt = concept.lastSeenAt
                if existing.extractorVersion < concept.extractorVersion {
                    existing.extractorVersion = concept.extractorVersion
                    existing.kind = concept.kind
                    existing.displayName = concept.displayName
                    existing.attributes = concept.attributes
                }
                try existing.update(db)
                return existing
            } else {
                var fresh = concept
                fresh.occurrences = 1
                try fresh.insert(db)
                return fresh
            }
        }
    }

    func updateAgentNotes(conceptID: String, notes: String?) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE concepts SET agent_notes = ? WHERE id = ?",
                arguments: [notes, conceptID]
            )
        }
    }

    /// Batched upsert. Used by `ConceptIngestor` after a scan so we do a single
    /// SQLite transaction for thousands of concepts instead of one transaction
    /// per concept (was ~20s of serial DB writes for a 6000-item scan).
    func batchUpsertConcepts(_ concepts: [Concept]) throws {
        guard !concepts.isEmpty,
              let dbQueue = dbQueue else { return }
        try dbQueue.write { db in
            for concept in concepts {
                if var existing = try Concept.fetchOne(db, key: concept.id) {
                    existing.occurrences += 1
                    existing.lastSeenAt = concept.lastSeenAt
                    if existing.extractorVersion < concept.extractorVersion {
                        existing.extractorVersion = concept.extractorVersion
                        existing.kind = concept.kind
                        existing.displayName = concept.displayName
                        existing.attributes = concept.attributes
                    }
                    try existing.update(db)
                } else {
                    var fresh = concept
                    fresh.occurrences = 1
                    try fresh.insert(db)
                }
            }
        }
    }

    private func fetchAllConceptsBlocking() throws -> [Concept] {
        guard let dbQueue = dbQueue else { return [] }
        return try dbQueue.read { db in try Concept.fetchAll(db) }
    }

    func allConcepts() throws -> [Concept] {
        try fetchAllConceptsBlocking()
    }

    func concepts(ofKind kind: ConceptKind) throws -> [Concept] {
        guard let dbQueue = dbQueue else { return [] }
        return try dbQueue.read { db in
            try Concept
                .filter(Concept.Columns.kind == kind.rawValue)
                .fetchAll(db)
        }
    }

    // MARK: - Item ↔ concept

    /// Persists item-concept associations for an item. Replaces any existing
    /// associations for the same fingerprint that originate from the same (or
    /// older) extractor version.
    func recordAssociations(
        fingerprintHash: String,
        signals: [(conceptID: String, signal: String?)],
        extractorVersion: Int,
        atDate date: Date = Date()
    ) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        try dbQueue.write { db in
            // Remove stale associations for this fingerprint (older or same extractor version
            // — we always re-extract fresh on a scan so old signals are discarded).
            try db.execute(
                sql: "DELETE FROM item_concepts WHERE fingerprint_hash = ? AND extractor_version <= ?",
                arguments: [fingerprintHash, extractorVersion]
            )
            for (conceptID, signal) in signals {
                let assoc = ItemConcept(
                    fingerprintHash: fingerprintHash,
                    conceptID: conceptID,
                    signal: signal,
                    extractorVersion: extractorVersion,
                    addedAt: date
                )
                try assoc.insert(db)
            }
        }
    }

    /// Batched association write. Used by `ConceptIngestor` to persist the
    /// fingerprint→concept links produced by a scan in one transaction. Old
    /// associations from the same (or older) extractor version are deleted
    /// first so the table only reflects the current extractor.
    func batchRecordAssociations(
        _ rows: [(fingerprintHash: String, conceptID: String, signal: String?)],
        extractorVersion: Int,
        atDate date: Date = Date()
    ) throws {
        guard !rows.isEmpty,
              let dbQueue = dbQueue else { return }
        try dbQueue.write { db in
            // Sweep stale associations for the fingerprints we're about to
            // re-write. Cheaper than per-row DELETE because we group by hash.
            let uniqueHashes = Set(rows.map(\.fingerprintHash))
            for hash in uniqueHashes {
                try db.execute(
                    sql: "DELETE FROM item_concepts WHERE fingerprint_hash = ? AND extractor_version <= ?",
                    arguments: [hash, extractorVersion]
                )
            }
            // Insert the fresh batch.
            let interval = date.timeIntervalSince1970
            for row in rows {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO item_concepts
                    (fingerprint_hash, concept_id, signal, extractor_version, added_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        row.fingerprintHash, row.conceptID, row.signal,
                        extractorVersion, interval
                    ]
                )
            }
        }
    }

    /// Batched edge upsert.
    func batchUpsertLinks(_ links: [ConceptLink]) throws {
        guard !links.isEmpty,
              let dbQueue = dbQueue else { return }
        try dbQueue.write { db in
            for link in links {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO concept_links
                    (from_id, to_id, relation, source, weight, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        link.fromID, link.toID, link.relation.rawValue,
                        link.source.rawValue, link.weight,
                        link.createdAt.timeIntervalSince1970
                    ]
                )
            }
        }
    }

    func conceptIDs(for fingerprintHash: String) throws -> [String] {
        guard let dbQueue = dbQueue else { return [] }
        return try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT concept_id FROM item_concepts WHERE fingerprint_hash = ?",
                arguments: [fingerprintHash]
            )
        }
    }

    func fingerprintHashes(forConcept conceptID: String, limit: Int? = nil) throws -> [String] {
        guard let dbQueue = dbQueue else { return [] }
        return try dbQueue.read { db in
            var sql = "SELECT fingerprint_hash FROM item_concepts WHERE concept_id = ?"
            if let limit { sql += " LIMIT \(limit)" }
            return try String.fetchAll(db, sql: sql, arguments: [conceptID])
        }
    }

    // MARK: - Links

    func upsertLink(_ link: ConceptLink) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO concept_links
                (from_id, to_id, relation, source, weight, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    link.fromID, link.toID, link.relation.rawValue,
                    link.source.rawValue, link.weight,
                    link.createdAt.timeIntervalSince1970
                ]
            )
        }
    }

    func allLinks() throws -> [ConceptLink] {
        guard let dbQueue = dbQueue else { return [] }
        return try dbQueue.read { db in try ConceptLink.fetchAll(db) }
    }

    func links(from id: String) throws -> [ConceptLink] {
        guard let dbQueue = dbQueue else { return [] }
        return try dbQueue.read { db in
            try ConceptLink
                .filter(ConceptLink.Columns.fromID == id)
                .fetchAll(db)
        }
    }

    // MARK: - Concept verdicts

    func attachVerdict(_ verdict: ConceptVerdict) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        try dbQueue.write { db in
            try verdict.insert(db)
        }
    }

    func verdicts(forConcept conceptID: String) throws -> [ConceptVerdict] {
        guard let dbQueue = dbQueue else { return [] }
        return try dbQueue.read { db in
            try ConceptVerdict
                .filter(ConceptVerdict.Columns.conceptID == conceptID)
                .order(ConceptVerdict.Columns.confirmedAt.desc)
                .fetchAll(db)
        }
    }

    // MARK: - Counts (cheap, for UI badges)

    func conceptCount() throws -> Int {
        guard let dbQueue = dbQueue else { return 0 }
        return try dbQueue.read { db in try Concept.fetchCount(db) }
    }

    func linkCount() throws -> Int {
        guard let dbQueue = dbQueue else { return 0 }
        return try dbQueue.read { db in try ConceptLink.fetchCount(db) }
    }

    func itemConceptCount() throws -> Int {
        guard let dbQueue = dbQueue else { return 0 }
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item_concepts") ?? 0
        }
    }
}
