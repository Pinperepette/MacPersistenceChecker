import Foundation

/// Applies rules from the knowledge graph to a PersistenceItem.
///
/// Cache invariant: `evaluate()` NEVER touches disk. The rules are loaded
/// asynchronously in the background and assigned to the in-memory cache; until
/// the first load completes, evaluations return `.unknown`. After mutations
/// (`invalidate()`), the *old* cache stays usable while a new load runs in the
/// background — there is no main-thread stall.
final class RuleMatcher: @unchecked Sendable {
    static let shared = RuleMatcher()

    private let store: KnowledgeGraphStore
    private let lock = NSLock()
    private var cachedRules: [KnowledgeRule] = []
    private var loadedAtLeastOnce = false
    private var pendingTask: Task<Void, Never>?

    init(store: KnowledgeGraphStore = .shared) {
        self.store = store
    }

    /// Snapshot of currently cached rules (thread-safe copy).
    private func snapshot() -> (rules: [KnowledgeRule], loaded: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (cachedRules, loadedAtLeastOnce)
    }

    /// Triggers an asynchronous load. Call once at app launch. Subsequent calls
    /// are coalesced — only one load runs at a time. Old cache stays usable.
    func preload() {
        scheduleReload()
    }

    /// Mark the cache stale and start a background reload. The current cache
    /// remains usable until the new one is ready, so callers never block.
    func invalidate() {
        scheduleReload()
    }

    /// Synchronously refreshes the cache from the store. Slower than
    /// `invalidate()` (which debounces by 200ms in a background task) but
    /// guarantees that the next `evaluate()` reflects the mutation.
    ///
    /// Use after explicit user actions (Trust this item / pattern, Analyze
    /// with AI) that must see their effect in the very next filter pass —
    /// the async invalidate would lose the race against the filter pipeline's
    /// 80ms Combine debounce.
    func reloadSync() {
        let rules = (try? store.enabledRules()) ?? []
        lock.lock()
        cachedRules = rules
        loadedAtLeastOnce = true
        pendingTask?.cancel()
        pendingTask = nil
        lock.unlock()
    }

    private func scheduleReload() {
        let storeRef = store
        lock.lock()
        // If a reload is already pending, just let it absorb the change —
        // creating a new task per invalidate would pile up under heavy
        // mutation (e.g. cluster batch propagation inserts dozens of rules).
        if let pending = pendingTask, !pending.isCancelled {
            lock.unlock()
            return
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            // Small debounce so a burst of invalidations within a few hundred
            // ms collapses into one reload.
            try? await Task.sleep(nanoseconds: 200_000_000)
            let rules = (try? storeRef.enabledRules()) ?? []
            guard let self else { return }
            self.lock.lock()
            self.cachedRules = rules
            self.loadedAtLeastOnce = true
            self.pendingTask = nil
            self.lock.unlock()
        }
        pendingTask = task
        lock.unlock()
    }

    /// Synchronous, in-memory only. Returns `.unknown` if the cache hasn't
    /// been loaded yet (initial preload still in flight).
    ///
    /// When multiple rules match the same fingerprint (typical case: AI
    /// produced a low-confidence watchlist, then the user clicked Trust to
    /// override) we apply a deterministic ladder so the user's verdict wins:
    ///   1. user-defined wins over AI-extracted
    ///   2. within same source: most recently confirmed wins
    ///   3. within same source/timestamp: higher confidence wins
    func evaluate(item: PersistenceItem) -> GraphLookupResult {
        let (rules, loaded) = snapshot()
        guard loaded else { return .unknown }

        let fingerprint = ItemFingerprint.make(from: item)

        // 1. Single-item rules: exact fingerprint hash match (highest priority).
        let singleItemMatches = rules
            .filter { $0.scope == .singleItem && $0.sourceItems.contains(fingerprint.hash) }
        if let rule = strongestRule(among: singleItemMatches) {
            return verdict(from: rule)
        }

        // 2. Pattern rules: predicate evaluation. Same ladder.
        let patternMatches = rules
            .filter { $0.scope == .pattern && matches(predicate: $0.predicate, item: item, fingerprint: fingerprint) }
        if let rule = strongestRule(among: patternMatches) {
            return verdict(from: rule)
        }

        return .unknown
    }

    /// Picks the most authoritative rule from a set of candidates that all
    /// match the same item. Mirrors the ConceptResolver ladder so the two
    /// layers agree on what "wins" when there are conflicting verdicts.
    private func strongestRule(among candidates: [KnowledgeRule]) -> KnowledgeRule? {
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            // user-defined > aiExtracted
            if lhs.source != rhs.source {
                return lhs.source == .aiExtracted && rhs.source == .userDefined
            }
            // most recently confirmed wins
            if lhs.lastConfirmedAt != rhs.lastConfirmedAt {
                return lhs.lastConfirmedAt < rhs.lastConfirmedAt
            }
            // higher confidence wins on ties
            return lhs.confidence < rhs.confidence
        }
    }

    /// Compute current confidence for a rule.
    ///
    /// A freshly-saved rule must immediately exceed the filter threshold (0.7),
    /// otherwise user "Trust" actions and AI verdicts have no visible effect.
    /// We therefore start at the rule's declared confidence and apply only a
    /// staleness decay (kicks in after a month of no confirmations, floors at 0.5).
    /// No occurrence boost — those who confirm a rule early benefit from it
    /// immediately, and repeated sightings can't push above 1.0 anyway.
    func currentConfidence(of rule: KnowledgeRule) -> Double {
        let daysSince = Date().timeIntervalSince(rule.lastConfirmedAt) / 86_400
        let decay = max(0.5, 1.0 - max(0.0, daysSince - 30) / 90.0)
        return min(1.0, max(0.0, rule.confidence) * decay)
    }

    private func verdict(from rule: KnowledgeRule) -> GraphLookupResult {
        let conf = currentConfidence(of: rule)
        switch rule.verdict {
        case .benign:
            return .knownBenign(rule: rule, confidence: conf)
        case .watchlist:
            return .knownThreat(rule: rule, confidence: conf, isMalicious: false)
        case .malicious:
            return .knownThreat(rule: rule, confidence: conf, isMalicious: true)
        }
    }

    private func matches(predicate: RulePredicate, item: PersistenceItem, fingerprint: ItemFingerprint) -> Bool {
        guard !predicate.clauses.isEmpty else { return false }
        return predicate.clauses.allSatisfy { matches(clause: $0, item: item, fingerprint: fingerprint) }
    }

    private func matches(clause: RulePredicate.Clause, item: PersistenceItem, fingerprint: ItemFingerprint) -> Bool {
        switch clause {
        case .teamIDEquals(let team):
            return fingerprint.teamID == team

        case .bundleIDEquals(let bid):
            return item.bundleIdentifier == bid

        case .bundleIDPrefix(let prefix):
            return item.bundleIdentifier?.hasPrefix(prefix) ?? false

        case .pathEquals(let path):
            return fingerprint.pathNormalized == path

        case .pathPrefix(let prefix):
            return fingerprint.pathNormalized.contains(prefix)

        case .categoryEquals(let cat):
            return fingerprint.category == cat

        case .signatureValid:
            return item.signatureInfo?.isValid ?? false

        case .appleSigned:
            return item.signatureInfo?.isAppleSigned ?? false
        }
    }
}

/// Validates rules before insertion. Pattern rules without a cryptographic clause
/// are downgraded to single-item scope to prevent path-based whitelist attacks.
enum RuleValidator {
    enum ValidationError: Error, LocalizedError {
        case emptyPredicate
        case singleItemWithoutSourceItems

        var errorDescription: String? {
            switch self {
            case .emptyPredicate:
                return "Rule predicate must have at least one clause."
            case .singleItemWithoutSourceItems:
                return "Single-item rule must reference at least one fingerprint."
            }
        }
    }

    /// Validates and possibly transforms a rule. Returns a sanitized copy.
    static func validate(_ rule: KnowledgeRule) throws -> KnowledgeRule {
        guard !rule.predicate.clauses.isEmpty else {
            throw ValidationError.emptyPredicate
        }

        var sanitized = rule

        if sanitized.scope == .pattern, !sanitized.predicate.hasCryptographicClause {
            // Downgrade to single-item: pattern without cryptographic anchor is unsafe.
            sanitized.scope = .singleItem
            let extra = "[downgraded from pattern: predicate lacked cryptographic clause]"
            sanitized.rationale = sanitized.rationale.map { "\($0) \(extra)" } ?? extra
        }

        if sanitized.scope == .singleItem, sanitized.sourceItems.isEmpty {
            throw ValidationError.singleItemWithoutSourceItems
        }

        return sanitized
    }
}
