import Foundation
import GRDB

// MARK: - Verdict

enum KnowledgeVerdict: String, Codable, CaseIterable {
    case benign
    case watchlist
    case malicious
}

// MARK: - Rule source / scope

enum RuleSource: String, Codable {
    case aiExtracted
    case userDefined
}

enum RuleScope: String, Codable {
    /// Rule applies only to the exact fingerprint hash listed in `sourceItems`.
    case singleItem
    /// Rule applies to any item whose attributes match the predicate.
    /// MUST include at least one cryptographic attribute (teamID, signatureValid, etc.)
    /// or it is downgraded to `singleItem` by RuleValidator.
    case pattern
}

// MARK: - Predicate

/// Conjunctive predicate. All clauses must match for the rule to apply.
struct RulePredicate: Codable, Equatable {
    var clauses: [Clause]

    enum Clause: Codable, Equatable {
        case teamIDEquals(String)
        case bundleIDEquals(String)
        case bundleIDPrefix(String)
        case pathEquals(String)
        case pathPrefix(String)
        case categoryEquals(String)
        case signatureValid
        case appleSigned

        // Discriminator-based Codable
        private enum CodingKeys: String, CodingKey {
            case kind, value
        }

        private enum Kind: String, Codable {
            case teamIDEquals, bundleIDEquals, bundleIDPrefix
            case pathEquals, pathPrefix, categoryEquals
            case signatureValid, appleSigned
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(Kind.self, forKey: .kind)
            switch kind {
            case .teamIDEquals:    self = .teamIDEquals(try c.decode(String.self, forKey: .value))
            case .bundleIDEquals:  self = .bundleIDEquals(try c.decode(String.self, forKey: .value))
            case .bundleIDPrefix:  self = .bundleIDPrefix(try c.decode(String.self, forKey: .value))
            case .pathEquals:      self = .pathEquals(try c.decode(String.self, forKey: .value))
            case .pathPrefix:      self = .pathPrefix(try c.decode(String.self, forKey: .value))
            case .categoryEquals:  self = .categoryEquals(try c.decode(String.self, forKey: .value))
            case .signatureValid:  self = .signatureValid
            case .appleSigned:     self = .appleSigned
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .teamIDEquals(let v):    try c.encode(Kind.teamIDEquals, forKey: .kind);   try c.encode(v, forKey: .value)
            case .bundleIDEquals(let v):  try c.encode(Kind.bundleIDEquals, forKey: .kind); try c.encode(v, forKey: .value)
            case .bundleIDPrefix(let v):  try c.encode(Kind.bundleIDPrefix, forKey: .kind); try c.encode(v, forKey: .value)
            case .pathEquals(let v):      try c.encode(Kind.pathEquals, forKey: .kind);     try c.encode(v, forKey: .value)
            case .pathPrefix(let v):      try c.encode(Kind.pathPrefix, forKey: .kind);     try c.encode(v, forKey: .value)
            case .categoryEquals(let v):  try c.encode(Kind.categoryEquals, forKey: .kind); try c.encode(v, forKey: .value)
            case .signatureValid:         try c.encode(Kind.signatureValid, forKey: .kind)
            case .appleSigned:            try c.encode(Kind.appleSigned, forKey: .kind)
            }
        }

        /// Whether this clause carries cryptographic identity. Required for `pattern` scope.
        var isCryptographic: Bool {
            switch self {
            case .teamIDEquals, .signatureValid, .appleSigned:
                return true
            default:
                return false
            }
        }

        /// Human-readable rendering for the trust-pattern dialog preview.
        var displayText: String {
            switch self {
            case .teamIDEquals(let v):   return "TeamID = \(v)"
            case .bundleIDEquals(let v): return "Bundle ID = \(v)"
            case .bundleIDPrefix(let v): return "Bundle ID starts with \(v)"
            case .pathEquals(let v):     return "Path = \(v)"
            case .pathPrefix(let v):     return "Path starts with \(v)"
            case .categoryEquals(let v): return "Category = \(v)"
            case .signatureValid:        return "Signature valid"
            case .appleSigned:           return "Signed by Apple"
            }
        }
    }

    var hasCryptographicClause: Bool {
        clauses.contains { $0.isCryptographic }
    }
}

// MARK: - KnowledgeRule (DB record)

struct KnowledgeRule: Codable, Equatable {
    var id: String
    var source: RuleSource
    var scope: RuleScope
    var verdict: KnowledgeVerdict
    var predicate: RulePredicate
    var confidence: Double
    var occurrences: Int
    var sourceItems: [String]   // fingerprint hashes
    var rationale: String?
    var createdAt: Date
    var lastConfirmedAt: Date
    var disabled: Bool
}

// MARK: - GRDB row mapping

extension KnowledgeRule: FetchableRecord, PersistableRecord {
    static let databaseTableName = "knowledgeRules"

    enum Columns: String, ColumnExpression {
        case id, source, scope, verdict, predicateJSON, confidence
        case occurrences, sourceItemsJSON, rationale
        case createdAt, lastConfirmedAt, disabled
    }

    init(row: Row) throws {
        self.id = row[Columns.id]
        self.source = RuleSource(rawValue: row[Columns.source] ?? "") ?? .userDefined
        self.scope = RuleScope(rawValue: row[Columns.scope] ?? "") ?? .singleItem
        self.verdict = KnowledgeVerdict(rawValue: row[Columns.verdict] ?? "") ?? .benign

        let predJSON: String = row[Columns.predicateJSON] ?? "{\"clauses\":[]}"
        self.predicate = (try? JSONDecoder().decode(RulePredicate.self, from: Data(predJSON.utf8)))
            ?? RulePredicate(clauses: [])

        self.confidence = row[Columns.confidence] ?? 0.5
        self.occurrences = row[Columns.occurrences] ?? 1

        if let itemsJSON: String = row[Columns.sourceItemsJSON],
           let items = try? JSONDecoder().decode([String].self, from: Data(itemsJSON.utf8)) {
            self.sourceItems = items
        } else {
            self.sourceItems = []
        }

        self.rationale = row[Columns.rationale]

        let createdInterval: Double = row[Columns.createdAt] ?? Date().timeIntervalSince1970
        self.createdAt = Date(timeIntervalSince1970: createdInterval)
        let confirmedInterval: Double = row[Columns.lastConfirmedAt] ?? createdInterval
        self.lastConfirmedAt = Date(timeIntervalSince1970: confirmedInterval)
        self.disabled = row[Columns.disabled] ?? false
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.source] = source.rawValue
        container[Columns.scope] = scope.rawValue
        container[Columns.verdict] = verdict.rawValue

        let predData = try JSONEncoder().encode(predicate)
        container[Columns.predicateJSON] = String(data: predData, encoding: .utf8)

        container[Columns.confidence] = confidence
        container[Columns.occurrences] = occurrences

        let itemsData = try JSONEncoder().encode(sourceItems)
        container[Columns.sourceItemsJSON] = String(data: itemsData, encoding: .utf8)

        container[Columns.rationale] = rationale
        container[Columns.createdAt] = createdAt.timeIntervalSince1970
        container[Columns.lastConfirmedAt] = lastConfirmedAt.timeIntervalSince1970
        container[Columns.disabled] = disabled
    }
}

// MARK: - FingerprintRecord (DB record)

struct FingerprintRecord: Codable, Equatable {
    var fingerprintHash: String
    var teamID: String?
    var pathNormalized: String
    var bundleIdentifier: String?
    var category: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    var matchedRuleId: String?
    var occurrences: Int
}

extension FingerprintRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "knowledgeFingerprints"

    enum Columns: String, ColumnExpression {
        case fingerprintHash, teamID, pathNormalized, bundleIdentifier, category
        case firstSeenAt, lastSeenAt, matchedRuleId, occurrences
    }

    init(row: Row) throws {
        self.fingerprintHash = row[Columns.fingerprintHash]
        self.teamID = row[Columns.teamID]
        self.pathNormalized = row[Columns.pathNormalized]
        self.bundleIdentifier = row[Columns.bundleIdentifier]
        self.category = row[Columns.category]

        let firstInterval: Double = row[Columns.firstSeenAt] ?? Date().timeIntervalSince1970
        self.firstSeenAt = Date(timeIntervalSince1970: firstInterval)
        let lastInterval: Double = row[Columns.lastSeenAt] ?? firstInterval
        self.lastSeenAt = Date(timeIntervalSince1970: lastInterval)

        self.matchedRuleId = row[Columns.matchedRuleId]
        self.occurrences = row[Columns.occurrences] ?? 1
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.fingerprintHash] = fingerprintHash
        container[Columns.teamID] = teamID
        container[Columns.pathNormalized] = pathNormalized
        container[Columns.bundleIdentifier] = bundleIdentifier
        container[Columns.category] = category
        container[Columns.firstSeenAt] = firstSeenAt.timeIntervalSince1970
        container[Columns.lastSeenAt] = lastSeenAt.timeIntervalSince1970
        container[Columns.matchedRuleId] = matchedRuleId
        container[Columns.occurrences] = occurrences
    }
}

// MARK: - Lookup result

enum GraphLookupResult {
    case knownBenign(rule: KnowledgeRule, confidence: Double)
    case knownThreat(rule: KnowledgeRule, confidence: Double, isMalicious: Bool)
    case unknown
}
