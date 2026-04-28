import SwiftUI

/// Window that runs an AI review across all suspicious items in the current scan.
/// Items the AI clears land as benign rules in the knowledge graph; the main list
/// then auto-hides them via AppState.refreshFilter().
struct BulkAIAnalysisView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var coordinator = BulkAnalysisCoordinator()
    @StateObject private var aiConfig = AIConfiguration.shared

    @State private var hasPrepared = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !aiConfig.isAIActive {
                disabledView
            } else if coordinator.queue.isEmpty {
                emptyView
            } else {
                content
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            if !hasPrepared {
                hasPrepared = true
                prepareQueue()
            }
        }
        .onChange(of: coordinator.state) { newState in
            if newState == .finished || newState == .capReached || newState == .cancelled {
                appState.refreshFilter()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Review")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Send suspicious items to Claude. Cleared items will be auto-hidden from the main list.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("Calls today: \(aiConfig.callsTodayCount) / \(aiConfig.dailyCallCap)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
    }

    private var disabledView: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("AI is not active")
                .font(.headline)
            Text("Enable AI in Settings → AI and provide a valid API key.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 42))
                .foregroundColor(.green)
            Text("Nothing to review")
                .font(.headline)
            Text("All non-Apple items are already trusted by the knowledge graph.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var content: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            List {
                ForEach(coordinator.queue) { item in
                    BulkResultRow(
                        item: item,
                        result: coordinator.results[item.id] ?? .pending,
                        onTrust: { trustItem(item) }
                    )
                }
            }
            .listStyle(.inset)
        }
    }

    /// User-overrides the AI verdict for a specific item: writes a userDefined
    /// singleItem benign rule to the graph, then triggers a filter refresh
    /// so the main list hides it on the next pass.
    private func trustItem(_ item: PersistenceItem) {
        let fingerprint = ItemFingerprint.make(from: item)
        let rule = KnowledgeRule(
            id: UUID().uuidString,
            source: .userDefined,
            scope: .singleItem,
            verdict: .benign,
            predicate: RulePredicate(clauses: [.bundleIDEquals(item.bundleIdentifier ?? item.identifier)]),
            confidence: 0.95,
            occurrences: 1,
            sourceItems: [fingerprint.hash],
            rationale: "User override from AI Review — \(item.name)",
            createdAt: Date(),
            lastConfirmedAt: Date(),
            disabled: false
        )

        do {
            let validated = try RuleValidator.validate(rule)
            try KnowledgeGraphStore.shared.insertRule(validated)
            _ = try? KnowledgeGraphStore.shared.recordSighting(fingerprint, matchedRuleId: validated.id)
            RuleMatcher.shared.invalidate()
            appState.refreshFilter()
        } catch {
            NSLog("[BulkAIAnalysisView] Trust failed: %@", error.localizedDescription)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            stateLabel
            Spacer()
            if coordinator.state == .running {
                ProgressView(value: progressValue)
                    .frame(maxWidth: 220)
                Text("\(coordinator.currentIndex) / \(coordinator.queue.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                summaryChips
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06))
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch coordinator.state {
        case .idle:
            Label("\(coordinator.queue.count) items queued", systemImage: "list.bullet")
                .foregroundColor(.secondary)
        case .running:
            Label("Running…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundColor(.accentColor)
        case .finished:
            Label("Finished", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .cancelled:
            Label("Cancelled", systemImage: "xmark.circle.fill")
                .foregroundColor(.orange)
        case .capReached:
            Label("Daily cap reached", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        }
    }

    private var summaryChips: some View {
        HStack(spacing: 8) {
            chip("Benign", count: coordinator.summary.benign, color: .green)
            chip("Watch", count: coordinator.summary.watchlist, color: .orange)
            chip("Malicious", count: coordinator.summary.malicious, color: .red)
            if coordinator.summary.skipped > 0 {
                chip("Skipped", count: coordinator.summary.skipped, color: .gray)
            }
            if coordinator.summary.failed > 0 {
                chip("Failed", count: coordinator.summary.failed, color: .pink)
            }
        }
        .font(.caption)
    }

    private func chip(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(count)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }

    private var footer: some View {
        HStack {
            Button("Re-scan candidates") {
                prepareQueue()
            }
            .buttonStyle(.bordered)
            .disabled(coordinator.state == .running)

            Spacer()

            if coordinator.state == .running {
                Button("Cancel") {
                    coordinator.cancel()
                }
                .buttonStyle(.bordered)
            } else {
                Button(coordinator.state == .finished || coordinator.state == .capReached ? "Run again on remaining" : "Start review") {
                    coordinator.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.queue.isEmpty || !aiConfig.canMakeCall)
            }
        }
        .padding(16)
    }

    // MARK: - Logic

    private var progressValue: Double {
        guard !coordinator.queue.isEmpty else { return 0 }
        return Double(coordinator.currentIndex) / Double(coordinator.queue.count)
    }

    /// Picks items worth sending to AI: skip Apple-signed system items and
    /// items already trusted by the graph. Sort by risk score so the most
    /// suspicious are processed first.
    private func prepareQueue() {
        let candidates = appState.items
            .filter { item in
                if item.signatureInfo?.isAppleSigned == true { return false }
                if case .knownBenign(_, let conf) = RuleMatcher.shared.evaluate(item: item), conf >= 0.7 {
                    return false
                }
                return true
            }
            .sorted { ($0.riskScore ?? 0) > ($1.riskScore ?? 0) }

        coordinator.setQueue(candidates)
    }
}

// MARK: - Row

private struct BulkResultRow: View {
    let item: PersistenceItem
    let result: BulkAnalysisCoordinator.ItemResult
    let onTrust: () -> Void

    @State private var hasTrusted = false

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(item.identifier)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if case .success(let outcome) = result {
                    Text(outcome.explanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else if case .failed(let msg) = result {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                } else if case .skipped(let reason) = result {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            verdictPill

            // Trust override is meaningful only after a verdict is in.
            if case .success = result, !hasTrusted {
                Button {
                    onTrust()
                    hasTrusted = true
                } label: {
                    Label("Trust", systemImage: "checkmark.seal")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Override the AI verdict — mark this item as benign and hide it from the main list")
            } else if hasTrusted {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                    .help("Trusted by you")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch result {
        case .pending:
            Image(systemName: "circle.dotted").foregroundColor(.secondary)
        case .success(let outcome):
            switch outcome.verdict {
            case .benign:    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
            case .watchlist: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            case .malicious: Image(systemName: "exclamationmark.octagon.fill").foregroundColor(.red)
            }
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundColor(.pink)
        case .skipped:
            Image(systemName: "minus.circle").foregroundColor(.gray)
        }
    }

    @ViewBuilder
    private var verdictPill: some View {
        switch result {
        case .pending:
            EmptyView()
        case .success(let outcome):
            Text("\(outcome.verdict.rawValue) \(Int(outcome.confidence * 100))%")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(verdictBackground(outcome.verdict))
                .foregroundColor(.primary)
                .cornerRadius(4)
        case .failed:
            Text("error")
                .font(.caption2)
                .foregroundColor(.pink)
        case .skipped:
            Text("skipped")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func verdictBackground(_ verdict: KnowledgeVerdict) -> Color {
        switch verdict {
        case .benign:    return .green.opacity(0.18)
        case .watchlist: return .orange.opacity(0.18)
        case .malicious: return .red.opacity(0.18)
        }
    }
}
