import Foundation
import GRDB

// MARK: - Kind / Relation enums

enum ConceptKind: String, Codable, CaseIterable {
    case vendor          // identified by TeamID or appleSigned
    case software        // named app/service derived from bundle ID + path
    case pathCategory    // significant path prefix (e.g. /opt/homebrew)
    case pattern         // bundle-ID prefix or filename pattern
    case mechanism       // persistence category (launchAgent, dylib, etc.)
    case userDefined     // user-created grouping

    /// Specificity weight used by the verdict ladder. Higher = more specific.
    var specificity: Int {
        switch self {
        case .userDefined:   return 12
        case .vendor:        return 10
        case .software:      return 8
        case .pattern:       return 6
        case .pathCategory:  return 4
        case .mechanism:     return 2
        }
    }
}

enum ConceptRelation: String, Codable {
    case subsumes        // A is more general than B
    case instanceOf      // B is an instance of A (mirror of subsumes)
    case coOccurs        // A and B frequently appear together
    case sameVendor      // A and B share a vendor
}

enum ConceptLinkSource: String, Codable {
    case deterministic   // computed from concept-ID structure (prefix, etc.)
    case ai              // proposed by AI batch analysis
    case user            // manually created
}

enum ConceptVerdictSource: String, Codable {
    case aiExtracted
    case userDefined
    case seedKnownVendor
    case clusterAI       // verdict from a cluster batch run
}

// MARK: - Concept

struct Concept: Codable, Equatable, Identifiable {
    var id: String
    var kind: ConceptKind
    var displayName: String
    var attributes: [String: String]
    var extractorVersion: Int
    var occurrences: Int
    var firstSeenAt: Date
    var lastSeenAt: Date
    var agentNotes: String?
    var promotedAt: Date?

    static func make(
        id: String,
        kind: ConceptKind,
        displayName: String,
        extractorVersion: Int,
        attributes: [String: String] = [:],
        now: Date = Date()
    ) -> Concept {
        Concept(
            id: id,
            kind: kind,
            displayName: displayName,
            attributes: attributes,
            extractorVersion: extractorVersion,
            occurrences: 0,
            firstSeenAt: now,
            lastSeenAt: now,
            agentNotes: nil,
            promotedAt: nil
        )
    }
}

extension Concept: FetchableRecord, PersistableRecord {
    static let databaseTableName = "concepts"

    enum Columns: String, ColumnExpression {
        case id, kind
        case displayName = "display_name"
        case attributesJSON = "attributes_json"
        case extractorVersion = "extractor_version"
        case occurrences
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case agentNotes = "agent_notes"
        case promotedAt = "promoted_at"
    }

    init(row: Row) throws {
        self.id = row[Columns.id]
        self.kind = ConceptKind(rawValue: row[Columns.kind] ?? "") ?? .pattern
        self.displayName = row[Columns.displayName] ?? ""
        if let attrsJSON: String = row[Columns.attributesJSON],
           let data = attrsJSON.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            self.attributes = dict
        } else {
            self.attributes = [:]
        }
        self.extractorVersion = row[Columns.extractorVersion] ?? 1
        self.occurrences = row[Columns.occurrences] ?? 0
        let firstInterval: Double = row[Columns.firstSeenAt] ?? 0
        let lastInterval: Double = row[Columns.lastSeenAt] ?? firstInterval
        self.firstSeenAt = Date(timeIntervalSince1970: firstInterval)
        self.lastSeenAt = Date(timeIntervalSince1970: lastInterval)
        self.agentNotes = row[Columns.agentNotes]
        if let promoted: Double = row[Columns.promotedAt] {
            self.promotedAt = Date(timeIntervalSince1970: promoted)
        } else {
            self.promotedAt = nil
        }
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.kind] = kind.rawValue
        container[Columns.displayName] = displayName
        let attrsData = try JSONEncoder().encode(attributes)
        container[Columns.attributesJSON] = String(data: attrsData, encoding: .utf8)
        container[Columns.extractorVersion] = extractorVersion
        container[Columns.occurrences] = occurrences
        container[Columns.firstSeenAt] = firstSeenAt.timeIntervalSince1970
        container[Columns.lastSeenAt] = lastSeenAt.timeIntervalSince1970
        container[Columns.agentNotes] = agentNotes
        container[Columns.promotedAt] = promotedAt?.timeIntervalSince1970
    }
}

// MARK: - ConceptLink

struct ConceptLink: Codable, Equatable {
    var fromID: String
    var toID: String
    var relation: ConceptRelation
    var source: ConceptLinkSource
    var weight: Double
    var createdAt: Date
}

extension ConceptLink: FetchableRecord, PersistableRecord {
    static let databaseTableName = "concept_links"

    enum Columns: String, ColumnExpression {
        case fromID = "from_id"
        case toID = "to_id"
        case relation, source, weight
        case createdAt = "created_at"
    }

    init(row: Row) throws {
        self.fromID = row[Columns.fromID]
        self.toID = row[Columns.toID]
        self.relation = ConceptRelation(rawValue: row[Columns.relation] ?? "") ?? .subsumes
        self.source = ConceptLinkSource(rawValue: row[Columns.source] ?? "") ?? .deterministic
        self.weight = row[Columns.weight] ?? 1.0
        let interval: Double = row[Columns.createdAt] ?? 0
        self.createdAt = Date(timeIntervalSince1970: interval)
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.fromID] = fromID
        container[Columns.toID] = toID
        container[Columns.relation] = relation.rawValue
        container[Columns.source] = source.rawValue
        container[Columns.weight] = weight
        container[Columns.createdAt] = createdAt.timeIntervalSince1970
    }
}

// MARK: - ItemConcept association

struct ItemConcept: Codable, Equatable {
    var fingerprintHash: String
    var conceptID: String
    var signal: String?
    var extractorVersion: Int
    var addedAt: Date
}

extension ItemConcept: FetchableRecord, PersistableRecord {
    static let databaseTableName = "item_concepts"

    enum Columns: String, ColumnExpression {
        case fingerprintHash = "fingerprint_hash"
        case conceptID = "concept_id"
        case signal
        case extractorVersion = "extractor_version"
        case addedAt = "added_at"
    }

    init(row: Row) throws {
        self.fingerprintHash = row[Columns.fingerprintHash]
        self.conceptID = row[Columns.conceptID]
        self.signal = row[Columns.signal]
        self.extractorVersion = row[Columns.extractorVersion] ?? 1
        let interval: Double = row[Columns.addedAt] ?? 0
        self.addedAt = Date(timeIntervalSince1970: interval)
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.fingerprintHash] = fingerprintHash
        container[Columns.conceptID] = conceptID
        container[Columns.signal] = signal
        container[Columns.extractorVersion] = extractorVersion
        container[Columns.addedAt] = addedAt.timeIntervalSince1970
    }
}

// MARK: - ConceptVerdict (m:n with knowledgeRules)

struct ConceptVerdict: Codable, Equatable, Identifiable {
    var id: String
    var conceptID: String
    var ruleID: String
    var source: ConceptVerdictSource
    var weight: Double
    var createdAt: Date
    var confirmedAt: Date
}

extension ConceptVerdict: FetchableRecord, PersistableRecord {
    static let databaseTableName = "concept_verdicts"

    enum Columns: String, ColumnExpression {
        case id
        case conceptID = "concept_id"
        case ruleID = "rule_id"
        case source, weight
        case createdAt = "created_at"
        case confirmedAt = "confirmed_at"
    }

    init(row: Row) throws {
        self.id = row[Columns.id]
        self.conceptID = row[Columns.conceptID]
        self.ruleID = row[Columns.ruleID]
        self.source = ConceptVerdictSource(rawValue: row[Columns.source] ?? "") ?? .aiExtracted
        self.weight = row[Columns.weight] ?? 1.0
        let createdInterval: Double = row[Columns.createdAt] ?? 0
        let confirmedInterval: Double = row[Columns.confirmedAt] ?? createdInterval
        self.createdAt = Date(timeIntervalSince1970: createdInterval)
        self.confirmedAt = Date(timeIntervalSince1970: confirmedInterval)
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.conceptID] = conceptID
        container[Columns.ruleID] = ruleID
        container[Columns.source] = source.rawValue
        container[Columns.weight] = weight
        container[Columns.createdAt] = createdAt.timeIntervalSince1970
        container[Columns.confirmedAt] = confirmedAt.timeIntervalSince1970
    }
}

// MARK: - ClusterRecord

struct ClusterRecord: Codable, Equatable, Identifiable {
    var id: String { signatureHash }   // Identifiable conformance
    var signatureHash: String
    var conceptIDs: [String]
    var memberCount: Int
    var currentVerdict: KnowledgeVerdict?
    var lastClassifiedAt: Date?
}

extension ClusterRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "clusters"

    enum Columns: String, ColumnExpression {
        case signatureHash = "signature_hash"
        case conceptIDsJSON = "concept_ids_json"
        case memberCount = "member_count"
        case currentVerdict = "current_verdict"
        case lastClassifiedAt = "last_classified_at"
    }

    init(row: Row) throws {
        self.signatureHash = row[Columns.signatureHash]
        if let json: String = row[Columns.conceptIDsJSON],
           let data = json.data(using: .utf8),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.conceptIDs = ids
        } else {
            self.conceptIDs = []
        }
        self.memberCount = row[Columns.memberCount] ?? 0
        if let v: String = row[Columns.currentVerdict] {
            self.currentVerdict = KnowledgeVerdict(rawValue: v)
        } else {
            self.currentVerdict = nil
        }
        if let interval: Double = row[Columns.lastClassifiedAt] {
            self.lastClassifiedAt = Date(timeIntervalSince1970: interval)
        } else {
            self.lastClassifiedAt = nil
        }
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.signatureHash] = signatureHash
        let data = try JSONEncoder().encode(conceptIDs)
        container[Columns.conceptIDsJSON] = String(data: data, encoding: .utf8) ?? "[]"
        container[Columns.memberCount] = memberCount
        container[Columns.currentVerdict] = currentVerdict?.rawValue
        container[Columns.lastClassifiedAt] = lastClassifiedAt?.timeIntervalSince1970
    }
}
