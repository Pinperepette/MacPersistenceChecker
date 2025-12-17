import Foundation
import GRDB

/// Gestisce il database SQLite con GRDB
final class DatabaseManager {
    /// Shared instance
    static let shared = DatabaseManager()

    /// Database queue for all operations
    private(set) var dbQueue: DatabaseQueue?

    /// Database file URL
    private var databaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("MacPersistenceChecker", isDirectory: true)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)

        return appFolder.appendingPathComponent("persistence.db")
    }

    private init() {}

    /// Initialize the database
    func initialize() throws {
        dbQueue = try DatabaseQueue(path: databaseURL.path)
        try migrate()
    }

    /// Run database migrations
    private func migrate() throws {
        guard let dbQueue = dbQueue else { return }

        var migrator = DatabaseMigrator()

        // Migration 1: Initial schema
        migrator.registerMigration("v1_initial") { db in
            // Snapshots table
            try db.create(table: "snapshots") { t in
                t.column("id", .text).primaryKey()
                t.column("createdAt", .double).notNull()
                t.column("trigger", .text).notNull()
                t.column("note", .text)
                t.column("itemCount", .integer).notNull().defaults(to: 0)
            }

            // Snapshot items table
            try db.create(table: "snapshotItems") { t in
                t.autoIncrementedPrimaryKey("rowId")
                t.column("snapshotId", .text).notNull().references("snapshots", onDelete: .cascade)
                t.column("itemId", .text).notNull()
                t.column("identifier", .text).notNull()
                t.column("category", .text).notNull()
                t.column("name", .text).notNull()
                t.column("plistPath", .text)
                t.column("executablePath", .text)
                t.column("trustLevel", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("isLoaded", .boolean).notNull().defaults(to: false)
                t.column("signatureInfoJSON", .text)
                t.column("bundleIdentifier", .text)
                t.column("teamIdentifier", .text)
                t.column("programArguments", .text) // JSON array
                t.column("runAtLoad", .boolean)
                t.column("keepAlive", .boolean)
                t.column("plistModifiedAt", .double)
                t.column("binaryModifiedAt", .double)
            }

            try db.create(index: "idx_snapshotItems_snapshotId", on: "snapshotItems", columns: ["snapshotId"])
            try db.create(index: "idx_snapshotItems_category", on: "snapshotItems", columns: ["category"])
            try db.create(index: "idx_snapshotItems_identifier", on: "snapshotItems", columns: ["identifier"])

            // Disabled items table
            try db.create(table: "disabledItems") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("originalPath", .text).notNull()
                t.column("safePath", .text).notNull()
                t.column("identifier", .text).notNull()
                t.column("category", .text).notNull()
                t.column("disabledAt", .double).notNull()
                t.column("disabledMethod", .text).notNull()
                t.column("originalPlistContent", .text)
                t.column("wasLoaded", .boolean).notNull().defaults(to: false)
            }

            try db.create(index: "idx_disabledItems_identifier", on: "disabledItems", columns: ["identifier"])

            // Known vendors table
            try db.create(table: "knownVendors") { t in
                t.column("teamId", .text).primaryKey()
                t.column("vendorName", .text).notNull()
                t.column("category", .text)
                t.column("verified", .boolean).notNull().defaults(to: false)
                t.column("addedAt", .double).notNull()
                t.column("updatedAt", .double)
            }

            // App settings table
            try db.create(table: "appSettings") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
                t.column("updatedAt", .double).notNull()
            }
        }

        try migrator.migrate(dbQueue)
    }

    // MARK: - Snapshot Operations

    /// Save a snapshot with its items
    func saveSnapshot(_ snapshot: Snapshot, items: [PersistenceItem]) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            // Insert snapshot
            try db.execute(
                sql: """
                    INSERT INTO snapshots (id, createdAt, trigger, note, itemCount)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    snapshot.id.uuidString,
                    snapshot.createdAt.timeIntervalSince1970,
                    snapshot.trigger.rawValue,
                    snapshot.note,
                    items.count
                ]
            )

            // Insert items
            for item in items {
                let snapshotItem = SnapshotItem(snapshotId: snapshot.id, item: item)
                try insertSnapshotItem(snapshotItem, in: db)
            }
        }
    }

    private func insertSnapshotItem(_ item: SnapshotItem, in db: Database) throws {
        let programArgsJSON: String?
        if let args = item.programArguments {
            let data = try JSONEncoder().encode(args)
            programArgsJSON = String(data: data, encoding: .utf8)
        } else {
            programArgsJSON = nil
        }

        try db.execute(
            sql: """
                INSERT INTO snapshotItems (
                    snapshotId, itemId, identifier, category, name,
                    plistPath, executablePath, trustLevel, isEnabled, isLoaded,
                    signatureInfoJSON, bundleIdentifier, teamIdentifier,
                    programArguments, runAtLoad, keepAlive,
                    plistModifiedAt, binaryModifiedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                item.snapshotId.uuidString,
                item.itemId.uuidString,
                item.identifier,
                item.category.rawValue,
                item.name,
                item.plistPath,
                item.executablePath,
                item.trustLevel.rawValue,
                item.isEnabled,
                item.isLoaded,
                item.signatureInfoJSON,
                item.bundleIdentifier,
                item.teamIdentifier,
                programArgsJSON,
                item.runAtLoad,
                item.keepAlive,
                item.plistModifiedAt?.timeIntervalSince1970,
                item.binaryModifiedAt?.timeIntervalSince1970
            ]
        )
    }

    /// Get all snapshots ordered by date
    func getAllSnapshots() throws -> [Snapshot] {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM snapshots ORDER BY createdAt DESC
                """)

            let logMsg = "📊 Found \(rows.count) snapshot rows in database\n"
            try? logMsg.write(toFile: "/tmp/mpc_debug.log", atomically: false, encoding: .utf8)

            return rows.compactMap { row -> Snapshot? in
                let idString = row["id"] as? String
                let id = idString.flatMap { UUID(uuidString: $0) }
                let createdAtInterval = row["createdAt"] as? Double
                let triggerString = row["trigger"] as? String
                let trigger = triggerString.flatMap { SnapshotTrigger(rawValue: $0) }
                // Try Int64 first, then Int
                let itemCount = (row["itemCount"] as? Int64).map { Int($0) } ?? (row["itemCount"] as? Int)

                guard let id = id,
                      let createdAtInterval = createdAtInterval,
                      let trigger = trigger,
                      let itemCount = itemCount else {
                    let errMsg = "⚠️ Failed: id=\(idString ?? "nil"), trigger=\(triggerString ?? "nil"), itemCount=\(String(describing: row["itemCount"]))\n"
                    if let handle = FileHandle(forWritingAtPath: "/tmp/mpc_debug.log") {
                        handle.seekToEndOfFile()
                        handle.write(errMsg.data(using: .utf8)!)
                        handle.closeFile()
                    }
                    return nil
                }

                return Snapshot(
                    id: id,
                    createdAt: Date(timeIntervalSince1970: createdAtInterval),
                    trigger: trigger,
                    note: row["note"] as? String,
                    itemCount: itemCount
                )
            }
        }
    }

    /// Get items for a specific snapshot
    func getItems(for snapshotId: UUID) throws -> [PersistenceItem] {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM snapshotItems WHERE snapshotId = ?
                """, arguments: [snapshotId.uuidString])

            return rows.compactMap { row -> PersistenceItem? in
                guard let categoryString = row["category"] as? String,
                      let category = PersistenceCategory(rawValue: categoryString),
                      let trustLevelString = row["trustLevel"] as? String,
                      let trustLevel = TrustLevel(rawValue: trustLevelString) else {
                    return nil
                }

                let itemIdString = row["itemId"] as? String ?? UUID().uuidString
                let itemId = UUID(uuidString: itemIdString) ?? UUID()

                var signatureInfo: SignatureInfo?
                if let sigJSON = row["signatureInfoJSON"] as? String,
                   let data = sigJSON.data(using: .utf8) {
                    signatureInfo = try? JSONDecoder().decode(SignatureInfo.self, from: data)
                }

                var programArgs: [String]?
                if let argsJSON = row["programArguments"] as? String,
                   let data = argsJSON.data(using: .utf8) {
                    programArgs = try? JSONDecoder().decode([String].self, from: data)
                }

                return PersistenceItem(
                    id: itemId,
                    identifier: row["identifier"] as? String ?? "",
                    category: category,
                    name: row["name"] as? String ?? "",
                    plistPath: (row["plistPath"] as? String).map { URL(fileURLWithPath: $0) },
                    executablePath: (row["executablePath"] as? String).map { URL(fileURLWithPath: $0) },
                    trustLevel: trustLevel,
                    signatureInfo: signatureInfo,
                    isEnabled: row["isEnabled"] as? Bool ?? true,
                    isLoaded: row["isLoaded"] as? Bool ?? false,
                    programArguments: programArgs,
                    runAtLoad: row["runAtLoad"] as? Bool,
                    keepAlive: row["keepAlive"] as? Bool,
                    bundleIdentifier: row["bundleIdentifier"] as? String,
                    plistModifiedAt: (row["plistModifiedAt"] as? Double).map { Date(timeIntervalSince1970: $0) },
                    binaryModifiedAt: (row["binaryModifiedAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
                )
            }
        }
    }

    /// Get the latest snapshot
    func getLatestSnapshot() throws -> Snapshot? {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM snapshots ORDER BY createdAt DESC LIMIT 1
                """) else {
                return nil
            }

            guard let idString = row["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let createdAtInterval = row["createdAt"] as? Double,
                  let triggerString = row["trigger"] as? String,
                  let trigger = SnapshotTrigger(rawValue: triggerString),
                  let itemCount = row["itemCount"] as? Int else {
                return nil
            }

            return Snapshot(
                id: id,
                createdAt: Date(timeIntervalSince1970: createdAtInterval),
                trigger: trigger,
                note: row["note"] as? String,
                itemCount: itemCount
            )
        }
    }

    /// Delete a snapshot and its items
    func deleteSnapshot(_ snapshotId: UUID) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM snapshots WHERE id = ?", arguments: [snapshotId.uuidString])
        }
    }

    // MARK: - Disabled Items

    /// Record a disabled item
    func recordDisabledItem(
        originalPath: String,
        safePath: String,
        identifier: String,
        category: PersistenceCategory,
        method: String,
        plistContent: String?,
        wasLoaded: Bool
    ) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO disabledItems (
                        originalPath, safePath, identifier, category,
                        disabledAt, disabledMethod, originalPlistContent, wasLoaded
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    originalPath,
                    safePath,
                    identifier,
                    category.rawValue,
                    Date().timeIntervalSince1970,
                    method,
                    plistContent,
                    wasLoaded
                ]
            )
        }
    }

    /// Get disabled item info for restore
    func getDisabledItem(identifier: String) throws -> DisabledItemInfo? {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM disabledItems WHERE identifier = ?
                """, arguments: [identifier]) else {
                return nil
            }

            return DisabledItemInfo(
                originalPath: row["originalPath"] as? String ?? "",
                safePath: row["safePath"] as? String ?? "",
                identifier: row["identifier"] as? String ?? "",
                category: PersistenceCategory(rawValue: row["category"] as? String ?? "") ?? .launchAgents,
                disabledAt: Date(timeIntervalSince1970: row["disabledAt"] as? Double ?? 0),
                method: row["disabledMethod"] as? String ?? "",
                originalPlistContent: row["originalPlistContent"] as? String,
                wasLoaded: row["wasLoaded"] as? Bool ?? false
            )
        }
    }

    /// Remove disabled item record after restore
    func removeDisabledItemRecord(identifier: String) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM disabledItems WHERE identifier = ?", arguments: [identifier])
        }
    }

    // MARK: - Known Vendors

    /// Check if a team ID is a known vendor
    func isKnownVendor(teamId: String) throws -> Bool {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM knownVendors WHERE teamId = ?
                """, arguments: [teamId]) ?? 0
            return count > 0
        }
    }

    /// Add a known vendor
    func addKnownVendor(teamId: String, name: String, category: String? = nil) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO knownVendors (teamId, vendorName, category, verified, addedAt)
                    VALUES (?, ?, ?, 1, ?)
                    """,
                arguments: [teamId, name, category, Date().timeIntervalSince1970]
            )
        }
    }

    // MARK: - Settings

    /// Get a setting value
    func getSetting(_ key: String) throws -> String? {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM appSettings WHERE key = ?", arguments: [key])
        }
    }

    /// Set a setting value
    func setSetting(_ key: String, value: String) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO appSettings (key, value, updatedAt)
                    VALUES (?, ?, ?)
                    """,
                arguments: [key, value, Date().timeIntervalSince1970]
            )
        }
    }
}

// MARK: - Supporting Types

struct DisabledItemInfo {
    let originalPath: String
    let safePath: String
    let identifier: String
    let category: PersistenceCategory
    let disabledAt: Date
    let method: String
    let originalPlistContent: String?
    let wasLoaded: Bool
}

enum DatabaseError: Error, LocalizedError {
    case notInitialized
    case migrationFailed(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Database not initialized"
        case .migrationFailed(let msg):
            return "Migration failed: \(msg)"
        case .queryFailed(let msg):
            return "Query failed: \(msg)"
        }
    }
}
