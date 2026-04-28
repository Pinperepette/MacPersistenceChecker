import SwiftUI

/// "Ask the graph" — natural-language Q&A over the persistence inventory.
/// User types a question, AI returns matching items with rationale.
struct ThreatHuntView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var aiConfig = AIConfiguration.shared

    @State private var query: String = ""
    @State private var result: ThreatHuntAnalyst.ResolvedHuntResult?
    @State private var isHunting = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            queryBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 600)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle")
                .font(.title2)
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Threat Hunt")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Ask a question in plain language. AI returns the matching items.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if aiConfig.isAIActive {
                Text("AI calls today: \(aiConfig.callsTodayCount) / \(aiConfig.dailyCallCap)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
    }

    private var queryBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.cursor")
                    .foregroundColor(.secondary)
                TextField("e.g. 'anything that auto-runs and connects to network'", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await runHunt() }
                    }
                Button {
                    Task { await runHunt() }
                } label: {
                    if isHunting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Hunting…")
                        }
                    } else {
                        Label("Ask", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canHunt)
            }

            // Suggested example queries the user can click to quickstart.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.exampleQueries, id: \.self) { ex in
                        Button {
                            query = ex
                        } label: {
                            Text(ex)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if !aiConfig.isAIActive {
            placeholder(
                icon: "brain",
                title: "AI is not active",
                detail: "Enable AI in Settings → AI."
            )
        } else if let result = result {
            resultsList(result)
        } else if isHunting {
            VStack(spacing: 12) {
                ProgressView()
                Text("AI is reading your inventory…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            placeholder(
                icon: "magnifyingglass.circle",
                title: "Type a question above",
                detail: "AI looks at your persistence items, finds matches, and explains why each one matched. ~$0.003 per call."
            )
        }
    }

    private func resultsList(_ result: ThreatHuntAnalyst.ResolvedHuntResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI rationale")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Text(result.rationale)
                    .font(.caption)
                    .textSelection(.enabled)
                if !result.mitreTechniques.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("MITRE: \(result.mitreTechniques.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.06))

            Divider()

            if result.matches.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                    Text("No items matched")
                        .font(.headline)
                    Text("AI understood the query but found nothing in your scan that fits.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(result.matches, id: \.item.id) { (item, note) in
                    matchRow(item: item, note: note)
                }
                .listStyle(.inset)
            }
        }
    }

    private func matchRow(item: PersistenceItem, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: itemIcon(item))
                    .foregroundColor(itemColor(item))
                    .frame(width: 22)
                Text(item.name)
                    .font(.subheadline.bold())
                Spacer()
                if let risk = item.riskScore, risk > 0 {
                    Text("risk \(risk)")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            Text(item.identifier)
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
                .lineLimit(1)
            if !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            // Jump to this item in the main list
            appState.selectedItem = item
            appState.selectedCategory = item.category
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let status = statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let result = result {
                Text("\(result.matches.count) matches")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
    }

    private func placeholder(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Logic

    private var canHunt: Bool {
        aiConfig.isAIActive
            && aiConfig.canMakeCall
            && !appState.items.isEmpty
            && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isHunting
    }

    private func runHunt() async {
        guard canHunt else { return }
        isHunting = true
        statusMessage = nil
        defer { isHunting = false }
        do {
            let result = try await ThreatHuntAnalyst.shared.hunt(query: query, in: appState.items)
            self.result = result
            statusMessage = "Hunt complete · \(result.matches.count) matches"
        } catch let err as ThreatHuntAnalyst.HuntError {
            statusMessage = err.errorDescription
        } catch {
            statusMessage = "Hunt failed: \(error.localizedDescription)"
        }
    }

    private func itemIcon(_ item: PersistenceItem) -> String {
        switch item.trustLevel {
        case .apple: return "checkmark.shield.fill"
        case .knownVendor: return "checkmark.shield.fill"
        case .signed: return "checkmark.shield"
        case .unsigned: return "exclamationmark.triangle"
        case .suspicious: return "exclamationmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func itemColor(_ item: PersistenceItem) -> Color {
        switch item.trustLevel {
        case .apple: return .green
        case .knownVendor: return .green
        case .signed: return .blue
        case .unsigned: return .orange
        case .suspicious: return .red
        case .unknown: return .gray
        }
    }

    private static let exampleQueries: [String] = [
        "anything that auto-runs and connects to the network",
        "items that look like cryptominers",
        "remote access tools with full disk or accessibility",
        "shell scripts that run as root",
        "anything in /tmp or hidden user directories",
        "items with curl or wget in their arguments"
    ]
}
