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

        // Migration 2: Containment Actions
        migrator.registerMigration("v2_containment") { db in
            try db.create(table: "containmentActions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("itemIdentifier", .text).notNull()
                t.column("itemCategory", .text).notNull()
                t.column("actionType", .text).notNull()
                t.column("timestamp", .double).notNull()
                t.column("binaryPath", .text)
                t.column("binaryHash", .text)
                t.column("plistPath", .text)
                t.column("plistBackup", .text)
                t.column("networkRuleId", .text)
                t.column("networkAnchor", .text)
                t.column("networkMethod", .text)
                t.column("status", .text).notNull()
                t.column("expiresAt", .double)
                t.column("details", .text)
            }

            try db.create(index: "idx_containment_identifier", on: "containmentActions", columns: ["itemIdentifier"])
            try db.create(index: "idx_containment_status", on: "containmentActions", columns: ["status"])
            try db.create(index: "idx_containment_timestamp", on: "containmentActions", columns: ["timestamp"])

            // Active network rules table (for persistence across app restarts)
            try db.create(table: "activeNetworkRules") { t in
                t.column("id", .text).primaryKey()
                t.column("anchor", .text).notNull()
                t.column("binaryPath", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("expiresAt", .double)
                t.column("method", .text).notNull()
                t.column("itemIdentifier", .text).notNull()
            }
        }

        // Migration 3: Monitor Baseline
        migrator.registerMigration("v3_monitor_baseline") { db in
            // Baseline items table - stores current state for comparison
            try db.create(table: "monitorBaseline") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("identifier", .text).notNull()
                t.column("category", .text).notNull()
                t.column("itemJSON", .text).notNull()
                t.column("capturedAt", .double).notNull()
            }

            try db.create(index: "idx_baseline_category", on: "monitorBaseline", columns: ["category"])
            try db.create(index: "idx_baseline_identifier", on: "monitorBaseline", columns: ["identifier"])

            // Change history table - logs all detected changes
            try db.create(table: "monitorChangeHistory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("changeId", .text).notNull().unique()
                t.column("changeType", .text).notNull()
                t.column("category", .text).notNull()
                t.column("itemIdentifier", .text)
                t.column("itemName", .text)
                t.column("detailsJSON", .text)
                t.column("relevanceScore", .integer).notNull()
                t.column("timestamp", .double).notNull()
                t.column("acknowledged", .boolean).notNull().defaults(to: false)
            }

            try db.create(index: "idx_changehistory_timestamp", on: "monitorChangeHistory", columns: ["timestamp"])
            try db.create(index: "idx_changehistory_category", on: "monitorChangeHistory", columns: ["category"])
            try db.create(index: "idx_changehistory_acknowledged", on: "monitorChangeHistory", columns: ["acknowledged"])
        }

        // Migration 4: Last scan cache - persist scan results between app launches
        migrator.registerMigration("v4_last_scan_cache") { db in
            try db.create(table: "lastScanItems") { t in
                t.autoIncrementedPrimaryKey("rowId")
                t.column("identifier", .text).notNull()
                t.column("itemJSON", .text).notNull()
            }

            try db.create(index: "idx_lastscan_identifier", on: "lastScanItems", columns: ["identifier"], unique: true)

            // Metadata table for scan info
            try db.create(table: "lastScanMeta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text)
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

    // MARK: - Containment Actions

    /// Save a containment action
    func saveContainmentAction(_ action: ContainmentAction) throws -> ContainmentAction {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.write { db in
            var mutableAction = action
            try mutableAction.insert(db)
            return mutableAction
        }
    }

    /// Get the latest active containment for an item
    func getActiveContainment(for identifier: String) throws -> ContainmentAction? {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            try ContainmentAction
                .filter(ContainmentAction.Columns.itemIdentifier == identifier)
                .filter(ContainmentAction.Columns.status == ContainmentStatus.active.rawValue)
                .order(ContainmentAction.Columns.timestamp.desc)
                .fetchOne(db)
        }
    }

    /// Get all containment actions for an item
    func getContainmentHistory(for identifier: String) throws -> [ContainmentAction] {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            try ContainmentAction
                .filter(ContainmentAction.Columns.itemIdentifier == identifier)
                .order(ContainmentAction.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }

    /// Get all active containments
    func getAllActiveContainments() throws -> [ContainmentAction] {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            try ContainmentAction
                .filter(ContainmentAction.Columns.status == ContainmentStatus.active.rawValue)
                .order(ContainmentAction.Columns.timestamp.desc)
                .fetchAll(db)
        }
    }

    /// Update containment status
    func updateContainmentStatus(id: Int64, status: ContainmentStatus) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE containmentActions SET status = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }

    /// Check if item is contained
    func isItemContained(identifier: String) throws -> Bool {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            let count = try ContainmentAction
                .filter(ContainmentAction.Columns.itemIdentifier == identifier)
                .filter(ContainmentAction.Columns.status == ContainmentStatus.active.rawValue)
                .fetchCount(db)
            return count > 0
        }
    }

    // MARK: - Active Network Rules

    /// Save an active network rule
    func saveNetworkRule(_ rule: NetworkRule, itemIdentifier: String) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO activeNetworkRules
                    (id, anchor, binaryPath, createdAt, expiresAt, method, itemIdentifier)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    rule.id,
                    rule.anchor,
                    rule.binaryPath,
                    rule.createdAt.timeIntervalSince1970,
                    rule.expiresAt?.timeIntervalSince1970,
                    rule.method.rawValue,
                    itemIdentifier
                ]
            )
        }
    }

    /// Get all active network rules
    func getActiveNetworkRules() throws -> [(rule: NetworkRule, itemIdentifier: String)] {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM activeNetworkRules")

            return rows.compactMap { row -> (NetworkRule, String)? in
                guard let id = row["id"] as? String,
                      let anchor = row["anchor"] as? String,
                      let binaryPath = row["binaryPath"] as? String,
                      let createdAtInterval = row["createdAt"] as? Double,
                      let methodString = row["method"] as? String,
                      let method = NetworkBlockMethod(rawValue: methodString),
                      let itemIdentifier = row["itemIdentifier"] as? String else {
                    return nil
                }

                let expiresAt = (row["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0) }

                let rule = NetworkRule(
                    id: id,
                    anchor: anchor,
                    binaryPath: binaryPath,
                    createdAt: Date(timeIntervalSince1970: createdAtInterval),
                    expiresAt: expiresAt,
                    method: method
                )

                return (rule, itemIdentifier)
            }
        }
    }

    /// Remove a network rule
    func removeNetworkRule(id: String) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM activeNetworkRules WHERE id = ?", arguments: [id])
        }
    }

    /// Get network rule for item
    func getNetworkRule(for identifier: String) throws -> NetworkRule? {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM activeNetworkRules WHERE itemIdentifier = ?
                """, arguments: [identifier]) else {
                return nil
            }

            guard let id = row["id"] as? String,
                  let anchor = row["anchor"] as? String,
                  let binaryPath = row["binaryPath"] as? String,
                  let createdAtInterval = row["createdAt"] as? Double,
                  let methodString = row["method"] as? String,
                  let method = NetworkBlockMethod(rawValue: methodString) else {
                return nil
            }

            let expiresAt = (row["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0) }

            return NetworkRule(
                id: id,
                anchor: anchor,
                binaryPath: binaryPath,
                createdAt: Date(timeIntervalSince1970: createdAtInterval),
                expiresAt: expiresAt,
                method: method
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

    // MARK: - Monitor Baseline Operations

    /// Save baseline items for a category
    func saveBaseline(items: [PersistenceItem], for category: PersistenceCategory) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            // Remove existing baseline for this category
            try db.execute(
                sql: "DELETE FROM monitorBaseline WHERE category = ?",
                arguments: [category.rawValue]
            )

            // Insert new baseline items
            let encoder = JSONEncoder()
            for item in items {
                let itemData = try encoder.encode(item)
                let itemJSON = String(data: itemData, encoding: .utf8) ?? "{}"

                try db.execute(
                    sql: """
                        INSERT INTO monitorBaseline (identifier, category, itemJSON, capturedAt)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        item.identifier,
                        category.rawValue,
                        itemJSON,
                        Date().timeIntervalSince1970
                    ]
                )
            }
        }
    }

    /// Get baseline items for a category
    func getBaseline(for category: PersistenceCategory) throws -> [PersistenceItem] {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT itemJSON FROM monitorBaseline WHERE category = ?",
                arguments: [category.rawValue]
            )

            let decoder = JSONDecoder()
            return rows.compactMap { row -> PersistenceItem? in
                guard let json = row["itemJSON"] as? String,
                      let data = json.data(using: .utf8) else {
                    return nil
                }
                return try? decoder.decode(PersistenceItem.self, from: data)
            }
        }
    }

    /// Check if baseline exists
    func hasBaseline() throws -> Bool {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM monitorBaseline") ?? 0
            return count > 0
        }
    }

    /// Get baseline capture date
    func getBaselineDate() throws -> Date? {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            guard let timestamp = try Double.fetchOne(
                db,
                sql: "SELECT MIN(capturedAt) FROM monitorBaseline"
            ) else {
                return nil
            }
            return Date(timeIntervalSince1970: timestamp)
        }
    }

    /// Clear all baseline data
    func clearBaseline() throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM monitorBaseline")
        }
    }

    // MARK: - Monitor Change History Operations

    /// Save a change to history
    func saveChangeHistory(_ entry: ChangeHistoryEntry) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        let encoder = JSONEncoder()
        let detailsJSON: String?
        if !entry.details.isEmpty {
            let data = try encoder.encode(entry.details)
            detailsJSON = String(data: data, encoding: .utf8)
        } else {
            detailsJSON = nil
        }

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO monitorChangeHistory
                    (changeId, changeType, category, itemIdentifier, itemName, detailsJSON, relevanceScore, timestamp, acknowledged)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    entry.id.uuidString,
                    entry.changeType.rawValue,
                    entry.category.rawValue,
                    entry.itemIdentifier,
                    entry.itemName,
                    detailsJSON,
                    entry.relevanceScore,
                    entry.timestamp.timeIntervalSince1970,
                    entry.acknowledged
                ]
            )
        }
    }

    /// Get recent changes (unacknowledged)
    func getUnacknowledgedChanges(limit: Int = 50) throws -> [ChangeHistoryEntry] {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM monitorChangeHistory
                    WHERE acknowledged = 0
                    ORDER BY timestamp DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )

            return rows.compactMap { parseChangeHistoryRow($0) }
        }
    }

    /// Get all change history
    func getChangeHistory(limit: Int = 100) throws -> [ChangeHistoryEntry] {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM monitorChangeHistory
                    ORDER BY timestamp DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )

            return rows.compactMap { parseChangeHistoryRow($0) }
        }
    }

    /// Acknowledge a change
    func acknowledgeChange(id: UUID) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE monitorChangeHistory SET acknowledged = 1 WHERE changeId = ?",
                arguments: [id.uuidString]
            )
        }
    }

    /// Acknowledge all changes
    func acknowledgeAllChanges() throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        try dbQueue.write { db in
            try db.execute(sql: "UPDATE monitorChangeHistory SET acknowledged = 1")
        }
    }

    /// Get unacknowledged change count
    func getUnacknowledgedChangeCount() throws -> Int {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM monitorChangeHistory WHERE acknowledged = 0"
            ) ?? 0
        }
    }

    /// Clear old change history (keep last N days)
    func pruneChangeHistory(olderThanDays: Int = 30) throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        let cutoffDate = Date().addingTimeInterval(-Double(olderThanDays * 24 * 60 * 60))

        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM monitorChangeHistory WHERE timestamp < ?",
                arguments: [cutoffDate.timeIntervalSince1970]
            )
        }
    }

    private func parseChangeHistoryRow(_ row: Row) -> ChangeHistoryEntry? {
        guard let changeIdString = row["changeId"] as? String,
              let changeId = UUID(uuidString: changeIdString),
              let changeTypeString = row["changeType"] as? String,
              let changeType = MonitorChangeType(rawValue: changeTypeString),
              let categoryString = row["category"] as? String,
              let category = PersistenceCategory(rawValue: categoryString),
              let relevanceScore = row["relevanceScore"] as? Int64,
              let timestamp = row["timestamp"] as? Double else {
            return nil
        }

        var details: [MonitorChangeDetail] = []
        if let detailsJSON = row["detailsJSON"] as? String,
           let data = detailsJSON.data(using: .utf8) {
            details = (try? JSONDecoder().decode([MonitorChangeDetail].self, from: data)) ?? []
        }

        return ChangeHistoryEntry(
            id: changeId,
            changeType: changeType,
            category: category,
            itemIdentifier: row["itemIdentifier"] as? String,
            itemName: row["itemName"] as? String,
            details: details,
            relevanceScore: Int(relevanceScore),
            timestamp: Date(timeIntervalSince1970: timestamp),
            acknowledged: row["acknowledged"] as? Bool ?? false
        )
    }
}

// MARK: - Last Scan Cache

extension DatabaseManager {
    /// Save the last scan results for quick loading on next app launch
    func saveLastScan(items: [PersistenceItem], scanDate: Date) throws {
        guard let dbQueue = dbQueue else {
            NSLog("[DatabaseManager] saveLastScan: Database not initialized!")
            throw DatabaseError.notInitialized
        }

        NSLog("[DatabaseManager] saveLastScan: Starting save of %d items...", items.count)

        try dbQueue.write { db in
            // Clear existing items
            try db.execute(sql: "DELETE FROM lastScanItems")
            try db.execute(sql: "DELETE FROM lastScanMeta")
            NSLog("[DatabaseManager] saveLastScan: Cleared old data")

            // Save each item as JSON
            let encoder = JSONEncoder()
            var savedCount = 0
            for item in items {
                let jsonData = try encoder.encode(item)
                let jsonString = String(data: jsonData, encoding: .utf8) ?? ""

                try db.execute(
                    sql: "INSERT OR REPLACE INTO lastScanItems (identifier, itemJSON) VALUES (?, ?)",
                    arguments: [item.identifier, jsonString]
                )
                savedCount += 1
            }
            NSLog("[DatabaseManager] saveLastScan: Saved %d items", savedCount)

            // Save metadata
            try db.execute(
                sql: "INSERT INTO lastScanMeta (key, value) VALUES (?, ?)",
                arguments: ["scanDate", String(scanDate.timeIntervalSince1970)]
            )
            try db.execute(
                sql: "INSERT INTO lastScanMeta (key, value) VALUES (?, ?)",
                arguments: ["itemCount", String(items.count)]
            )
            NSLog("[DatabaseManager] saveLastScan: Saved metadata")
        }

        NSLog("[DatabaseManager] saveLastScan: SUCCESS - Saved %d items to cache", items.count)
    }

    /// Load the last scan results
    func loadLastScan() throws -> (items: [PersistenceItem], scanDate: Date?)? {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }

        return try dbQueue.read { db in
            // Check if we have cached items
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lastScanItems") ?? 0
            guard count > 0 else { return nil }

            // Load metadata
            var scanDate: Date? = nil
            if let row = try Row.fetchOne(db, sql: "SELECT value FROM lastScanMeta WHERE key = 'scanDate'"),
               let dateStr = row["value"] as? String,
               let timestamp = Double(dateStr) {
                scanDate = Date(timeIntervalSince1970: timestamp)
            }

            // Load items
            let decoder = JSONDecoder()
            var items: [PersistenceItem] = []

            let rows = try Row.fetchAll(db, sql: "SELECT itemJSON FROM lastScanItems")
            for row in rows {
                if let jsonString = row["itemJSON"] as? String,
                   let jsonData = jsonString.data(using: .utf8),
                   let item = try? decoder.decode(PersistenceItem.self, from: jsonData) {
                    items.append(item)
                }
            }

            print("[DatabaseManager] Loaded \(items.count) items from last scan cache")
            return (items, scanDate)
        }
    }

    /// Check if we have a cached scan
    func hasLastScan() -> Bool {
        guard let dbQueue = dbQueue else { return false }
        return (try? dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lastScanItems") ?? 0
            return count > 0
        }) ?? false
    }

    /// Clear the last scan cache
    func clearLastScan() throws {
        guard let dbQueue = dbQueue else { throw DatabaseError.notInitialized }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM lastScanItems")
            try db.execute(sql: "DELETE FROM lastScanMeta")
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
