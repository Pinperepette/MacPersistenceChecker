import SwiftUI

/// Cluster-first triage. The user sees concept clusters from the current scan
/// rather than 5000+ individual items. They can: trust a cluster (creates a
/// concept verdict that propagates to every member), mark watchlist/malicious,
/// or send the unresolved clusters to AI in a single batched call.
struct SmartTriageView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var aiConfig = AIConfiguration.shared

    @State private var clusters: [ConceptCluster] = []
    @State private var isRefreshing = false
    @State private var isAnalyzing = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statsBar
            Divider()
            clusterList
            Divider()
            footer
        }
        .frame(minWidth: 820, minHeight: 600)
        .onAppear { rebuild() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.title2)
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Triage")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Decide once per cluster — verdicts propagate to every item linked to the same concepts.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                rebuild()
            } label: {
                if isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing…")
                    }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing)
        }
        .padding(16)
    }

    private var statsBar: some View {
        let unclassified = clusters.filter(\.needsClassification).count
        let pendingAI = clusters.filter { $0.needsClassification && !$0.aiAnalyzed }.count
        let classified = clusters.count - unclassified
        return HStack(spacing: 16) {
            chip("Total", count: clusters.count, color: .secondary)
            chip("Classified", count: classified, color: .green)
            chip("Unclassified", count: unclassified, color: .orange)
            chip("Pending AI", count: pendingAI, color: .blue)
            Spacer()
            if aiConfig.isAIActive {
                Text("AI calls today: \(aiConfig.callsTodayCount) / \(aiConfig.dailyCallCap)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
    }

    private var clusterList: some View {
        Group {
            if clusters.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(clusters) { cluster in
                        ClusterCard(
                            cluster: cluster,
                            onTrust: { applyVerdict(.benign, to: cluster) },
                            onWatch: { applyVerdict(.watchlist, to: cluster) },
                            onBlock: { applyVerdict(.malicious, to: cluster) }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text(appState.items.isEmpty ? "No scan results" : "No clusters yet")
                .font(.headline)
            Text(appState.items.isEmpty
                 ? "Run a scan first."
                 : "Refresh to extract concept clusters from the current scan.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if allClustersResolved {
                Label("All clusters classified", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else if let status = statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                Task { await sendUnresolvedToAI() }
            } label: {
                if isAnalyzing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Running AI batch…")
                    }
                } else {
                    Label("Send unresolved clusters to AI", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSendToAI || isAnalyzing)
        }
        .padding(16)
    }

    /// True when there is nothing left for the user (or AI) to triage:
    /// every cluster either has a verdict, or AI already tried and stored
    /// a low-confidence opinion. Used by the footer to switch from a
    /// status line to a "done" badge.
    private var allClustersResolved: Bool {
        !clusters.isEmpty && !clusters.contains { $0.needsClassification && !$0.aiAnalyzed }
    }

    private func chip(_ label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(count)")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }

    // MARK: - Actions

    private var canSendToAI: Bool {
        aiConfig.isAIActive
            && aiConfig.canMakeCall
            && clusters.contains { $0.needsClassification && !$0.aiAnalyzed }
    }

    private func rebuild() {
        isRefreshing = true
        let items = appState.items
        let builder = ClusterBuilder.shared
        Task.detached(priority: .userInitiated) {
            let result = builder.buildClusters(from: items)
            await MainActor.run {
                self.clusters = result
                self.isRefreshing = false
                self.statusMessage = "\(result.count) clusters built from \(items.count) items"
            }
        }
    }

    private func sendUnresolvedToAI() async {
        isAnalyzing = true
        statusMessage = nil
        defer { isAnalyzing = false }
        do {
            let outcome = try await ClusterBatchAnalyst.shared.analyze(clusters: clusters)
            statusMessage = "AI: \(outcome.appliedVerdicts) verdicts applied · \(outcome.apiCallsMade) calls"
            ClusterBuilder.shared.invalidateCache()
            rebuild()
            appState.refreshFilter()
        } catch let err as ClusterBatchAnalyst.BatchError {
            statusMessage = err.errorDescription
        } catch {
            statusMessage = "AI batch failed: \(error.localizedDescription)"
        }
    }

    private func applyVerdict(_ verdict: KnowledgeVerdict, to cluster: ConceptCluster) {
        ClusterBuilder.shared.invalidateCache()
        // Pick a target concept for the user-defined verdict: prefer the most
        // specific concept (software → vendor → pattern → path → mechanism).
        let priorityOrder: [String] = ["software:", "vendor:", "pattern:", "path:", "mechanism:"]
        let conceptID = priorityOrder.lazy
            .compactMap { prefix in cluster.conceptIDs.first { $0.hasPrefix(prefix) } }
            .first ?? cluster.conceptIDs.first

        guard let target = conceptID else { return }

        let now = Date()
        let predicate = RulePredicate(clauses: [.categoryEquals("__concept__:\(target)")])
        let rule = KnowledgeRule(
            id: UUID().uuidString,
            source: .userDefined,
            scope: .singleItem,
            verdict: verdict,
            predicate: predicate,
            confidence: 0.95,
            occurrences: cluster.memberItems.count,
            sourceItems: cluster.memberFingerprints,
            rationale: "User triage on cluster \(cluster.displayLabel)",
            createdAt: now,
            lastConfirmedAt: now,
            disabled: false
        )
        do {
            try KnowledgeGraphStore.shared.insertRule(rule)
            let verdictRecord = ConceptVerdict(
                id: UUID().uuidString,
                conceptID: target,
                ruleID: rule.id,
                source: .userDefined,
                weight: 1.0,
                createdAt: now,
                confirmedAt: now
            )
            try ConceptStore.shared.attachVerdict(verdictRecord)
            ConceptResolver.shared.invalidate()
            statusMessage = "Marked \(cluster.memberItems.count) items as \(verdict.rawValue)"
            rebuild()
            appState.refreshFilter()
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Cluster card

private struct ClusterCard: View {
    let cluster: ConceptCluster
    let onTrust: () -> Void
    let onWatch: () -> Void
    let onBlock: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(cluster.memberItems.count) items")
                    .font(.headline)
                Text("·")
                    .foregroundColor(.secondary)
                Text(cluster.displayLabel)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                verdictBadge
            }

            HStack(spacing: 4) {
                ForEach(cluster.conceptIDs, id: \.self) { id in
                    Text(shortConcept(id))
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(3)
                        .lineLimit(1)
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cluster.sampleItems) { item in
                        Text("• \(item.name)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if cluster.memberItems.count > cluster.sampleItems.count {
                        Text("… +\(cluster.memberItems.count - cluster.sampleItems.count) more")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    Label(expanded ? "Hide samples" : "Show samples",
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(action: onTrust) {
                    Label("Trust", systemImage: "checkmark.seal")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button(action: onWatch) {
                    Label("Watch", systemImage: "eye.trianglebadge.exclamationmark")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button(action: onBlock) {
                    Label("Block", systemImage: "exclamationmark.octagon")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var verdictBadge: some View {
        HStack(spacing: 4) {
            if let verdict = cluster.currentVerdict {
                Text(verdict.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(verdictColor(verdict).opacity(0.18))
                    .foregroundColor(verdictColor(verdict))
                    .cornerRadius(4)
            } else if cluster.aiAnalyzed {
                Text("AI: low conf.")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .cornerRadius(4)
                    .help("AI has analyzed this cluster but its confidence was below the gate. Use Trust to lock in a benign verdict yourself.")
            } else {
                Text("unclassified")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func verdictColor(_ v: KnowledgeVerdict) -> Color {
        switch v {
        case .benign:    return .green
        case .watchlist: return .orange
        case .malicious: return .red
        }
    }

    /// Pretty-prints a concept ID for the chip row, dropping the kind prefix
    /// when there's room and truncating long values gracefully.
    private func shortConcept(_ id: String) -> String {
        if let colon = id.firstIndex(of: ":") {
            let kind = id[..<colon]
            let rest = id[id.index(after: colon)...]
            return "\(kind):\(rest)"
        }
        return id
    }
}
