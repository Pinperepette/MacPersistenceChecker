import Foundation

/// Drives a sequential AI review of multiple persistence items.
///
/// One ItemAnalyst call per item — this respects the existing daily cap and
/// the knowledge graph's rule extraction (each call may add a rule that
/// short-circuits future siblings). Stops automatically when the cap is hit.
@MainActor
final class BulkAnalysisCoordinator: ObservableObject {

    enum State: Equatable {
        case idle
        case running
        case finished
        case cancelled
        case capReached
    }

    /// Outcome of one item's analysis. Either a verdict from the AI or an error.
    enum ItemResult {
        case pending
        case success(ItemAnalyst.AnalysisOutcome)
        case failed(String)
        case skipped(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var queue: [PersistenceItem] = []
    @Published private(set) var results: [UUID: ItemResult] = [:]
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var summary: Summary = Summary()

    struct Summary: Equatable {
        var benign: Int = 0
        var watchlist: Int = 0
        var malicious: Int = 0
        var failed: Int = 0
        var skipped: Int = 0
    }

    private var task: Task<Void, Never>?
    private let analyst = ItemAnalyst.shared

    // MARK: - Public API

    /// Prepare the queue. Caller passes the items they want reviewed.
    func setQueue(_ items: [PersistenceItem]) {
        guard state != .running else { return }
        queue = items
        results = Dictionary(uniqueKeysWithValues: items.map { ($0.id, .pending) })
        currentIndex = 0
        summary = Summary()
        state = .idle
    }

    /// Begin processing.
    func start() {
        guard state != .running, !queue.isEmpty else { return }
        state = .running
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Stop after the current item completes.
    func cancel() {
        task?.cancel()
        if state == .running {
            state = .cancelled
        }
    }

    /// Reset everything for a new run.
    func reset() {
        cancel()
        queue = []
        results = [:]
        currentIndex = 0
        summary = Summary()
        state = .idle
    }

    // MARK: - Loop

    private func runLoop() async {
        let total = queue.count
        var i = 0
        while i < total {
            if Task.isCancelled { break }

            // Cap check before each call so we surface "cap reached" cleanly.
            if !AIConfiguration.shared.canMakeCall {
                state = .capReached
                // Mark remaining items as skipped.
                for j in i..<total {
                    let item = queue[j]
                    results[item.id] = .skipped("Daily cap reached")
                    summary.skipped += 1
                }
                return
            }

            currentIndex = i
            let item = queue[i]

            // If the graph already classifies this item with high confidence,
            // skip the API call — we already know the answer.
            if case .knownBenign(_, let conf) = RuleMatcher.shared.evaluate(item: item), conf >= 0.7 {
                results[item.id] = .skipped("Already trusted by graph")
                summary.skipped += 1
                i += 1
                continue
            }

            do {
                let outcome = try await analyst.analyze(item: item)
                results[item.id] = .success(outcome)
                switch outcome.verdict {
                case .benign:    summary.benign += 1
                case .watchlist: summary.watchlist += 1
                case .malicious: summary.malicious += 1
                }
            } catch let err as ItemAnalyst.AnalystError {
                if case .dailyCapReached = err {
                    state = .capReached
                    for j in i..<total {
                        let it = queue[j]
                        results[it.id] = .skipped("Daily cap reached")
                        summary.skipped += 1
                    }
                    return
                }
                results[item.id] = .failed(err.errorDescription ?? "AI error")
                summary.failed += 1
            } catch {
                results[item.id] = .failed(error.localizedDescription)
                summary.failed += 1
            }

            i += 1
        }

        if Task.isCancelled {
            state = .cancelled
        } else {
            state = .finished
            currentIndex = total
        }
    }
}
