import SwiftUI

/// Detail-view section that exposes knowledge-graph state for the selected item:
/// current verdict (if any) and Trust Item / Trust Pattern actions.
struct KnowledgeGraphSection: View {
    let item: PersistenceItem

    @EnvironmentObject var appState: AppState
    @StateObject private var aiConfig = AIConfiguration.shared
    @State private var lookup: GraphLookupResult = .unknown
    @State private var showTrustPatternSheet = false
    @State private var feedbackMessage: String?
    @State private var isAnalyzing = false
    @State private var analysisOutcome: ItemAnalyst.AnalysisOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Knowledge Graph", icon: "brain")

            statusRow

            HStack(spacing: 12) {
                if isUserTrusted {
                    Button(role: .destructive) {
                        removeTrust()
                    } label: {
                        Label("Remove trust", systemImage: "xmark.seal")
                    }
                    .buttonStyle(.bordered)
                    .help("Delete the user-defined trust rule(s) you added on this item.")
                } else {
                    Button {
                        trustThisItem()
                    } label: {
                        Label("Trust this item", systemImage: "checkmark.seal")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAlreadyTrusted)

                    Button {
                        showTrustPatternSheet = true
                    } label: {
                        Label("Trust this pattern", systemImage: "checkmark.seal.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canTrustPattern)
                }

                Button {
                    Task { await analyzeWithAI() }
                } label: {
                    if isAnalyzing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Analyzing…")
                        }
                    } else {
                        Label("Analyze with AI", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAnalyzeWithAI || isAnalyzing)
            }

            if aiConfig.isAIActive {
                Text("AI calls today: \(aiConfig.callsTodayCount) / \(aiConfig.dailyCallCap) (\(aiConfig.callsRemainingToday) remaining)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let outcome = analysisOutcome {
                analysisOutcomeView(outcome)
            }

            if let msg = feedbackMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !canTrustPattern {
                Text("Pattern trust requires a TeamID or Apple-signed status. Use Trust this item for unsigned binaries.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { reloadLookup() }
        .sheet(isPresented: $showTrustPatternSheet, onDismiss: { reloadLookup() }) {
            TrustPatternSheet(item: item) {
                feedbackMessage = "Pattern saved to graph"
                showTrustPatternSheet = false
                ConceptResolver.shared.invalidate()
                appState.refreshFilter()
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        switch lookup {
        case .knownBenign(let rule, let confidence):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text("Trusted via \(sourceLabel(rule.source))")
                    .font(.subheadline)
                Text("(\(Int(confidence * 100))%)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

        case .knownThreat(let rule, let confidence, let isMalicious):
            HStack(spacing: 6) {
                Image(systemName: isMalicious ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(isMalicious ? .red : .orange)
                Text(isMalicious ? "Marked malicious" : "Watchlisted")
                    .font(.subheadline)
                Text("via \(sourceLabel(rule.source)) (\(Int(confidence * 100))%)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

        case .unknown:
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle").foregroundColor(.secondary)
                Text("No graph verdict yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private func sourceLabel(_ source: RuleSource) -> String {
        switch source {
        case .userDefined:  return "user"
        case .aiExtracted:  return "AI"
        }
    }

    // MARK: - Computed gates

    private var isAlreadyTrusted: Bool {
        if case .knownBenign = lookup { return true }
        return false
    }

    /// True if the current verdict comes from a user-defined rule. Drives the
    /// "Remove trust" button — we only let the user undo their own actions,
    /// not AI-extracted verdicts (those should be challenged via Analyze with
    /// AI re-runs or by trusting the item explicitly).
    private var isUserTrusted: Bool {
        if case .knownBenign(let rule, _) = lookup, rule.source == .userDefined {
            return true
        }
        return false
    }

    private var canTrustPattern: Bool {
        // Pattern needs cryptographic anchor (TeamID or Apple-signed).
        return item.signatureInfo?.teamIdentifier != nil || (item.signatureInfo?.isAppleSigned ?? false)
    }

    private var canAnalyzeWithAI: Bool {
        aiConfig.isAIActive && aiConfig.canMakeCall
    }

    @ViewBuilder
    private func analysisOutcomeView(_ outcome: ItemAnalyst.AnalysisOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: verdictIcon(outcome.verdict))
                    .foregroundColor(verdictColor(outcome.verdict))
                Text("AI verdict: \(outcome.verdict.rawValue)")
                    .font(.subheadline.bold())
                Text("(\(Int(outcome.confidence * 100))%)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(outcome.explanation)
                .font(.caption)
                .foregroundColor(.primary)
            if !outcome.mitreTechniques.isEmpty {
                Text("MITRE: \(outcome.mitreTechniques.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let scope = outcome.ruleScope {
                Text("Saved as \(scope == .pattern ? "pattern" : "single-item") rule")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("No rule extracted (verdict only)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    private func verdictIcon(_ verdict: KnowledgeVerdict) -> String {
        switch verdict {
        case .benign:    return "checkmark.seal.fill"
        case .watchlist: return "exclamationmark.triangle.fill"
        case .malicious: return "exclamationmark.octagon.fill"
        }
    }

    private func verdictColor(_ verdict: KnowledgeVerdict) -> Color {
        switch verdict {
        case .benign:    return .green
        case .watchlist: return .orange
        case .malicious: return .red
        }
    }

    // MARK: - Actions

    private func reloadLookup() {
        // Don't invalidate here — invalidate is async (200ms debounce) and
        // we'd read stale cache. Callers that just mutated rules should call
        // RuleMatcher.shared.reloadSync() before invoking reloadLookup so the
        // evaluate() below reads fresh state.
        lookup = RuleMatcher.shared.evaluate(item: item)
    }

    private func analyzeWithAI() async {
        isAnalyzing = true
        feedbackMessage = nil
        analysisOutcome = nil
        defer { isAnalyzing = false }

        do {
            let outcome = try await ItemAnalyst.shared.analyze(item: item)
            analysisOutcome = outcome
            reloadLookup()
            // Synchronously refresh the matcher cache before kicking the
            // filter pipeline — otherwise the filter races the async
            // RuleMatcher reload and the new trust rule isn't visible until
            // hundreds of ms later, leaving the red badge stale.
            RuleMatcher.shared.reloadSync()
            ConceptResolver.shared.invalidate()
            appState.refreshFilter()
        } catch let err as ItemAnalyst.AnalystError {
            feedbackMessage = err.errorDescription
        } catch {
            feedbackMessage = "Analysis failed: \(error.localizedDescription)"
        }
    }

    private func trustThisItem() {
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
            rationale: "Trusted by user — \(item.name)",
            createdAt: Date(),
            lastConfirmedAt: Date(),
            disabled: false
        )

        do {
            let validated = try RuleValidator.validate(rule)
            try KnowledgeGraphStore.shared.insertRule(validated)
            // Sighting is best-effort — must NOT abort the trust action even
            // if it fails. Rule is already saved at this point.
            _ = try? KnowledgeGraphStore.shared.recordSighting(fingerprint, matchedRuleId: validated.id)

            // ORDER MATTERS:
            // 1. reloadSync — pull the new rule into the matcher cache.
            // 2. ConceptResolver.invalidate — drop any stale rule snapshot.
            // 3. reloadLookup — re-read THIS view's verdict against the
            //    refreshed cache so the button switches to "Remove trust"
            //    and the badge shows "Trusted via user" immediately.
            // 4. appState.refreshFilter — kick the off-main filter pipeline
            //    so the sidebar Suspicious counter and the main list update.
            RuleMatcher.shared.reloadSync()
            ConceptResolver.shared.invalidate()
            reloadLookup()
            appState.refreshFilter()

            feedbackMessage = "Item trusted in graph"
        } catch {
            feedbackMessage = "Failed: \(error.localizedDescription)"
        }
    }

    /// Removes any user-defined trust rules linked to this item's fingerprint.
    /// Doesn't touch AI-extracted rules — only undoes what the user did.
    private func removeTrust() {
        let fingerprint = ItemFingerprint.make(from: item)
        do {
            let allRules = try KnowledgeGraphStore.shared.allRules()
            let toDelete = allRules.filter { rule in
                rule.source == .userDefined &&
                rule.scope == .singleItem &&
                rule.sourceItems.contains(fingerprint.hash)
            }
            for rule in toDelete {
                try KnowledgeGraphStore.shared.deleteRule(id: rule.id)
            }

            RuleMatcher.shared.reloadSync()
            ConceptResolver.shared.invalidate()
            reloadLookup()
            appState.refreshFilter()

            feedbackMessage = toDelete.isEmpty
                ? "No user trust rules to remove"
                : "Removed \(toDelete.count) user trust rule\(toDelete.count == 1 ? "" : "s")"
        } catch {
            feedbackMessage = "Remove failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Trust Pattern Sheet

private struct TrustPatternSheet: View {
    let item: PersistenceItem
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var includeTeamID = true
    @State private var includeBundlePrefix = false
    @State private var includeCategory = true
    @State private var includeSignatureValid = true
    @State private var bundlePrefix: String = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trust this pattern")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Future items matching all the clauses below will be auto-trusted (no AI call, no notification). Be conservative — broader patterns are riskier.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            clauseToggles

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Predicate preview")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                ForEach(previewClauses.indices, id: \.self) { i in
                    Text("• \(previewClauses[i].displayText)")
                        .font(.system(.caption, design: .monospaced))
                }
                if previewClauses.isEmpty {
                    Text("(no clauses selected)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(previewClauses.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private var clauseToggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let team = item.signatureInfo?.teamIdentifier {
                Toggle(isOn: $includeTeamID) {
                    Text("TeamID = \(team)").font(.system(.caption, design: .monospaced))
                }
            } else if item.signatureInfo?.isAppleSigned == true {
                Toggle(isOn: $includeSignatureValid) {
                    Text("Signed by Apple").font(.caption)
                }
            }

            Toggle(isOn: $includeCategory) {
                Text("Category = \(item.category.rawValue)").font(.caption)
            }

            if let bundle = item.bundleIdentifier {
                Toggle(isOn: $includeBundlePrefix) {
                    HStack {
                        Text("Bundle ID prefix").font(.caption)
                        TextField("e.g. com.example.", text: $bundlePrefix)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .disabled(!includeBundlePrefix)
                    }
                }
                .onAppear {
                    if bundlePrefix.isEmpty {
                        bundlePrefix = computeDefaultBundlePrefix(bundle)
                    }
                }
            }
        }
    }

    private var previewClauses: [RulePredicate.Clause] {
        var clauses: [RulePredicate.Clause] = []
        if includeTeamID, let team = item.signatureInfo?.teamIdentifier {
            clauses.append(.teamIDEquals(team))
        } else if includeSignatureValid, item.signatureInfo?.isAppleSigned == true {
            clauses.append(.appleSigned)
        }
        if includeCategory {
            clauses.append(.categoryEquals(item.category.rawValue))
        }
        if includeBundlePrefix, !bundlePrefix.isEmpty {
            clauses.append(.bundleIDPrefix(bundlePrefix))
        }
        return clauses
    }

    private func save() {
        let fingerprint = ItemFingerprint.make(from: item)
        let rule = KnowledgeRule(
            id: UUID().uuidString,
            source: .userDefined,
            scope: .pattern,
            verdict: .benign,
            predicate: RulePredicate(clauses: previewClauses),
            confidence: 0.9,
            occurrences: 1,
            sourceItems: [fingerprint.hash],
            rationale: "User-defined trust pattern from \(item.name)",
            createdAt: Date(),
            lastConfirmedAt: Date(),
            disabled: false
        )
        do {
            let validated = try RuleValidator.validate(rule)
            try KnowledgeGraphStore.shared.insertRule(validated)
            // Sighting is best-effort — must NOT abort the trust action even
            // if it fails (e.g. legacy GRDB autoincrement PK quirks). The
            // rule is already saved at this point.
            _ = try? KnowledgeGraphStore.shared.recordSighting(fingerprint, matchedRuleId: validated.id)
            onSaved()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func computeDefaultBundlePrefix(_ bundle: String) -> String {
        // Default to two-segment prefix: "com.example.foo.bar" -> "com.example."
        let parts = bundle.split(separator: ".")
        guard parts.count >= 2 else { return bundle }
        return parts.prefix(2).joined(separator: ".") + "."
    }
}
