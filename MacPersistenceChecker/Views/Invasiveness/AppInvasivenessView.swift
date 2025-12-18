import SwiftUI

/// Main view for App Invasiveness analysis
struct AppInvasivenessView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var analyzer = AppInvasivenessAnalyzer.shared
    @State private var selectedApp: AnalyzedApp?
    @State private var showingExportSheet = false
    @State private var sortBy: SortOption = .score

    enum SortOption: String, CaseIterable {
        case score = "Score"
        case size = "Size"
        case persistence = "Persistence"
        case name = "Name"
    }

    /// Total junk size across all apps
    private var totalJunkSize: String {
        let total = analyzer.analyzedApps.reduce(Int64(0)) { $0 + ($1.junkInfo?.totalSize ?? 0) }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// Sorted apps based on selected sort option
    private var sortedApps: [AnalyzedApp] {
        switch sortBy {
        case .score:
            return analyzer.analyzedApps.sorted { $0.invasivenessScore > $1.invasivenessScore }
        case .size:
            return analyzer.analyzedApps.sorted { ($0.junkInfo?.totalSize ?? 0) > ($1.junkInfo?.totalSize ?? 0) }
        case .persistence:
            return analyzer.analyzedApps.sorted { $0.totalPersistenceItems > $1.totalPersistenceItems }
        case .name:
            return analyzer.analyzedApps.sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }

    var body: some View {
        HSplitView {
            // Left: App list
            VStack(spacing: 0) {
                // Header with stats
                headerView

                Divider()

                if analyzer.isAnalyzing {
                    analysisProgressView
                } else if analyzer.analyzedApps.isEmpty {
                    emptyStateView
                } else {
                    appListView
                }
            }
            .frame(minWidth: 380, maxWidth: 500)

            // Right: Detail view
            if let app = selectedApp {
                AppScoreDetailView(app: app)
            } else {
                placeholderView
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                Text("App Invasiveness Report")
                    .font(.headline)

                Spacer()

                if !analyzer.analyzedApps.isEmpty {
                    Button(action: { showingExportSheet = true }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Export Report")
                }
            }

            if !analyzer.analyzedApps.isEmpty && !analyzer.isAnalyzing {
                // Stats row
                HStack(spacing: 12) {
                    StatBadge(
                        value: "\(analyzer.totalAppsAnalyzed)",
                        label: "Apps",
                        color: .blue
                    )
                    StatBadge(
                        value: "\(analyzer.invasiveApps)",
                        label: "Invasive",
                        color: .red
                    )
                    StatBadge(
                        value: totalJunkSize,
                        label: "Junk",
                        color: .orange
                    )
                    StatBadge(
                        value: "\(analyzer.analyzedApps.reduce(0) { $0 + $1.totalPersistenceItems })",
                        label: "Persistence",
                        color: .purple
                    )
                }

                // Sort options
                HStack {
                    Text("Sort by:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $sortBy) {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
            }

            // Analyze button
            Button(action: {
                Task {
                    await analyzer.analyzeAllApps(persistenceItems: appState.items)
                }
            }) {
                HStack {
                    Image(systemName: analyzer.isAnalyzing ? "stop.fill" : "magnifyingglass")
                    Text(analyzer.isAnalyzing ? "Scanning..." : "Analyze Apps")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(analyzer.isAnalyzing)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .fileExporter(
            isPresented: $showingExportSheet,
            document: TextDocument(text: analyzer.generateReport()),
            contentType: .plainText,
            defaultFilename: "AppInvasivenessReport.txt"
        ) { _ in }
    }

    // MARK: - Progress View

    private var analysisProgressView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView(value: analyzer.progress) {
                Text("Analyzing Apps...")
                    .font(.headline)
            } currentValueLabel: {
                Text(analyzer.currentApp)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .progressViewStyle(.linear)
            .padding(.horizontal, 40)

            Text("\(Int(analyzer.progress * 100))%")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.accentColor)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "apps.iphone")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Analysis Yet")
                .font(.headline)

            Text("Click \"Analyze Apps\" to scan your installed\napplications for persistence mechanisms.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if appState.items.isEmpty {
                Text("Run a scan first to gather persistence data.")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - App List

    private var appListView: some View {
        List(selection: $selectedApp) {
            ForEach(sortedApps) { app in
                AppScoreRow(app: app)
                    .tag(app)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.circle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Select an App")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Choose an app from the list to see\nits persistence details.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - App Score Row

struct AppScoreRow: View {
    let app: AnalyzedApp

    var body: some View {
        HStack(spacing: 12) {
            // Grade badge
            ZStack {
                Circle()
                    .fill(gradeColor.opacity(0.2))
                    .frame(width: 40, height: 40)

                Text(app.grade.rawValue)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(gradeColor)
            }

            // App info
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    // Persistence indicator
                    if app.totalPersistenceItems > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9))
                            Text("\(app.totalPersistenceItems)")
                                .font(.caption2)
                        }
                        .foregroundColor(.purple)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.1))
                        .cornerRadius(3)
                    }

                    // Junk indicator
                    if let junk = app.junkInfo, junk.totalSize > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 9))
                            Text(junk.formattedSize)
                                .font(.caption2)
                        }
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(3)
                    }
                }
            }

            Spacer()

            // Score
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(app.invasivenessScore)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(gradeColor)

                Text(app.grade.displayName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var gradeColor: Color {
        switch app.grade {
        case .clean, .good: return .green
        case .moderate: return .yellow
        case .invasive: return .orange
        case .veryInvasive: return .red
        case .unknown: return .gray
        }
    }
}

// MARK: - App Score Detail View

struct AppScoreDetailView: View {
    let app: AnalyzedApp
    @State private var selectedTab = 0
    @State private var calculatedJunkInfo: AppJunkInfo?
    @State private var isCalculatingSize = false
    @StateObject private var analyzer = AppInvasivenessAnalyzer.shared

    var displayJunkInfo: AppJunkInfo? {
        calculatedJunkInfo ?? app.junkInfo
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with overall score
                scoreHeader

                Divider()

                // Score breakdown cards
                scoreBreakdownCards

                Divider()

                // Tabs for details
                Picker("", selection: $selectedTab) {
                    Text("Persistence (\(app.totalPersistenceItems))").tag(0)
                    Text("Junk (\(app.totalJunkLocations))").tag(1)
                    Text("Details").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Tab content
                switch selectedTab {
                case 0:
                    persistenceSection
                case 1:
                    junkSection
                default:
                    scoreDetailsSection
                }
            }
            .padding()
        }
        .background(Color(NSColor.controlBackgroundColor))
        .task(id: app.id) {
            // Calculate sizes on demand when viewing this app
            if calculatedJunkInfo == nil && app.junkInfo != nil {
                isCalculatingSize = true
                calculatedJunkInfo = await analyzer.calculateSizeForApp(app)
                isCalculatingSize = false
            }
        }
        .onChange(of: app.id) { _ in
            calculatedJunkInfo = nil
        }
    }

    // MARK: - Score Header

    private var scoreHeader: some View {
        HStack(spacing: 20) {
            // Grade circle
            ZStack {
                Circle()
                    .fill(gradeColor.opacity(0.15))
                    .frame(width: 80, height: 80)

                Circle()
                    .stroke(gradeColor, lineWidth: 4)
                    .frame(width: 80, height: 80)

                VStack(spacing: 2) {
                    Text(app.grade.rawValue)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(gradeColor)

                    Text("\(app.invasivenessScore)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(app.name)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(app.grade.displayName)
                    .font(.subheadline)
                    .foregroundColor(gradeColor)

                HStack(spacing: 12) {
                    if app.totalPersistenceItems > 0 {
                        Label("\(app.totalPersistenceItems) persistence", systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundColor(.purple)
                    }
                    if let junk = displayJunkInfo {
                        if isCalculatingSize {
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.6)
                                Text("Calculating...")
                                    .font(.caption)
                            }
                            .foregroundColor(.orange)
                        } else if junk.totalSize > 0 {
                            Label(junk.formattedSize, systemImage: "trash.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else {
                            Label("\(junk.locations.count) locations", systemImage: "folder.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Score Breakdown Cards

    private var scoreBreakdownCards: some View {
        HStack(spacing: 16) {
            // Persistence Score
            ScoreCard(
                title: "Persistence",
                score: app.scoreDetails?.persistenceScore ?? 0,
                icon: "bolt.fill",
                color: .purple,
                description: persistenceDescription
            )

            // Junk Score
            ScoreCard(
                title: "Installation",
                score: app.scoreDetails?.junkScore ?? 0,
                icon: "trash.fill",
                color: .orange,
                description: junkDescription
            )
        }
    }

    private var persistenceDescription: String {
        var parts: [String] = []
        if !app.launchAgents.isEmpty { parts.append("\(app.launchAgents.count) agents") }
        if !app.launchDaemons.isEmpty { parts.append("\(app.launchDaemons.count) daemons") }
        if !app.privilegedHelpers.isEmpty { parts.append("\(app.privilegedHelpers.count) helpers") }
        if !app.kernelExtensions.isEmpty { parts.append("\(app.kernelExtensions.count) kexts") }
        return parts.isEmpty ? "No persistence items" : parts.joined(separator: ", ")
    }

    private var junkDescription: String {
        guard let junk = displayJunkInfo else { return "No files found" }
        if isCalculatingSize {
            return "\(junk.locations.count) locations, calculating..."
        }
        return "\(junk.locations.count) locations, \(junk.formattedSize)"
    }

    // MARK: - Persistence Section

    private var persistenceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if app.totalPersistenceItems == 0 {
                emptySection(icon: "checkmark.circle.fill", text: "No persistence mechanisms found", color: .green)
            } else {
                if !app.launchDaemons.isEmpty {
                    persistenceCategory(title: "Launch Daemons (Root)", items: app.launchDaemons, icon: "gearshape.fill", color: .red)
                }
                if !app.privilegedHelpers.isEmpty {
                    persistenceCategory(title: "Privileged Helpers", items: app.privilegedHelpers, icon: "lock.shield.fill", color: .red)
                }
                if !app.kernelExtensions.isEmpty {
                    persistenceCategory(title: "Kernel Extensions", items: app.kernelExtensions, icon: "cpu.fill", color: .purple)
                }
                if !app.systemExtensions.isEmpty {
                    persistenceCategory(title: "System Extensions", items: app.systemExtensions, icon: "puzzlepiece.extension.fill", color: .indigo)
                }
                if !app.launchAgents.isEmpty {
                    persistenceCategory(title: "Launch Agents", items: app.launchAgents, icon: "person.fill", color: .blue)
                }
                if !app.loginItems.isEmpty {
                    persistenceCategory(title: "Login Items", items: app.loginItems, icon: "person.badge.key.fill", color: .green)
                }
                if !app.otherItems.isEmpty {
                    persistenceCategory(title: "Other", items: app.otherItems, icon: "ellipsis.circle.fill", color: .gray)
                }
            }
        }
        .padding(.horizontal)
    }

    private func persistenceCategory(title: String, items: [PersistenceItem], icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.2))
                    .foregroundColor(color)
                    .cornerRadius(4)
            }

            ForEach(items, id: \.identifier) { item in
                persistenceItemRow(item, color: color)
            }
        }
    }

    private func persistenceItemRow(_ item: PersistenceItem, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))

                    // Flags
                    if item.runAtLoad == true {
                        Text("RunAtLoad")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.2))
                            .foregroundColor(.blue)
                            .cornerRadius(2)
                    }
                    if item.keepAlive == true {
                        Text("KeepAlive")
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.2))
                            .foregroundColor(.red)
                            .cornerRadius(2)
                    }
                }

                if let path = item.plistPath?.path {
                    Text(path)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Trust badge
            trustBadge(item.trustLevel)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        .cornerRadius(4)
    }

    private func trustBadge(_ level: TrustLevel) -> some View {
        Group {
            switch level {
            case .unsigned:
                Text("Unsigned")
                    .font(.caption2)
                    .foregroundColor(.orange)
            case .suspicious:
                Text("Suspicious")
                    .font(.caption2)
                    .foregroundColor(.red)
            case .signed:
                Text("Signed")
                    .font(.caption2)
                    .foregroundColor(.green)
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Junk Section

    private var junkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isCalculatingSize {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Calculating sizes...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 30)
                    Spacer()
                }
            } else if let junkInfo = displayJunkInfo, !junkInfo.locations.isEmpty {
                ForEach(Array(junkInfo.locations.sorted { $0.size > $1.size }.enumerated()), id: \.offset) { _, location in
                    locationRow(location)
                }
            } else {
                emptySection(icon: "checkmark.circle.fill", text: "No junk files found", color: .green)
            }
        }
        .padding(.horizontal)
    }

    private func locationRow(_ location: LibraryLocation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconForType(location.type))
                .foregroundColor(colorForType(location.type))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(location.type)
                    .font(.system(size: 12, weight: .medium))

                Text(location.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: location.size, countStyle: .file))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)

            Button(action: {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: location.path)
            }) {
                Image(systemName: "folder")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    // MARK: - Score Details Section

    private var scoreDetailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let details = app.scoreDetails {
                // Persistence details
                if !details.persistenceDetails.isEmpty {
                    detailsGroup(title: "Persistence Factors", details: details.persistenceDetails)
                }

                // Junk details
                if !details.junkDetails.isEmpty {
                    detailsGroup(title: "Installation Factors", details: details.junkDetails)
                }

                if details.persistenceDetails.isEmpty && details.junkDetails.isEmpty {
                    emptySection(icon: "checkmark.circle.fill", text: "No concerning factors found", color: .green)
                }
            } else {
                emptySection(icon: "questionmark.circle", text: "No score details available", color: .gray)
            }
        }
        .padding(.horizontal)
    }

    private func detailsGroup(title: String, details: [InvasivenessScorer.ScoreDetail]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                HStack(spacing: 8) {
                    Circle()
                        .fill(severityColor(detail.severity))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.description)
                            .font(.system(size: 12))
                        HStack {
                            Text(detail.category)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(detail.severity.rawValue)
                                .font(.caption2)
                                .foregroundColor(severityColor(detail.severity))
                        }
                    }

                    Spacer()

                    Text("+\(detail.points)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(severityColor(detail.severity))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                .cornerRadius(4)
            }
        }
    }

    // MARK: - Helper Views

    private func emptySection(icon: String, text: String, color: Color) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 30)
            Spacer()
        }
    }

    // MARK: - Helpers

    private var gradeColor: Color {
        switch app.grade {
        case .clean, .good: return .green
        case .moderate: return .yellow
        case .invasive: return .orange
        case .veryInvasive: return .red
        case .unknown: return .gray
        }
    }

    private func severityColor(_ severity: InvasivenessScorer.ScoreDetail.Severity) -> Color {
        switch severity {
        case .low: return .blue
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }

    private func iconForType(_ type: String) -> String {
        switch type {
        case "App Support": return "folder.fill"
        case "Caches": return "archivebox.fill"
        case "Preferences": return "gearshape.fill"
        case "Containers": return "shippingbox.fill"
        case "Group Containers": return "square.stack.3d.up.fill"
        case "Saved State": return "clock.arrow.circlepath"
        case "Logs": return "doc.text.fill"
        case "System App Support": return "folder.fill.badge.gearshape"
        case "System Caches": return "archivebox.fill"
        case "System Preferences": return "gearshape.2.fill"
        default: return "folder.fill"
        }
    }

    private func colorForType(_ type: String) -> Color {
        switch type {
        case "App Support", "System App Support": return .blue
        case "Caches", "System Caches": return .orange
        case "Preferences", "System Preferences": return .purple
        case "Containers", "Group Containers": return .green
        case "Saved State": return .gray
        case "Logs": return .yellow
        default: return .secondary
        }
    }
}

// MARK: - Score Card

struct ScoreCard: View {
    let title: String
    let score: Int
    let icon: String
    let color: Color
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
            }

            Text("\(score)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(scoreColor)

            Text(description)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
    }

    private var scoreColor: Color {
        switch score {
        case 0...20: return .green
        case 21...50: return .yellow
        case 51...70: return .orange
        default: return .red
        }
    }
}

// MARK: - Detail View

struct AppInvasivenessDetailView: View {
    let app: AnalyzedApp

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                appHeader

                Divider()

                // Score breakdown
                scoreBreakdown

                Divider()

                // Persistence items by category
                if !app.launchAgents.isEmpty {
                    categorySection(title: "Launch Agents", items: app.launchAgents, icon: "person.fill", color: .blue)
                }

                if !app.launchDaemons.isEmpty {
                    categorySection(title: "Launch Daemons", items: app.launchDaemons, icon: "gearshape.fill", color: .orange)
                }

                if !app.privilegedHelpers.isEmpty {
                    categorySection(title: "Privileged Helpers", items: app.privilegedHelpers, icon: "lock.shield.fill", color: .red)
                }

                if !app.kernelExtensions.isEmpty {
                    categorySection(title: "Kernel Extensions", items: app.kernelExtensions, icon: "cpu.fill", color: .purple)
                }

                if !app.systemExtensions.isEmpty {
                    categorySection(title: "System Extensions", items: app.systemExtensions, icon: "puzzlepiece.extension.fill", color: .indigo)
                }

                if !app.loginItems.isEmpty {
                    categorySection(title: "Login Items", items: app.loginItems, icon: "person.badge.key.fill", color: .green)
                }

                if !app.otherItems.isEmpty {
                    categorySection(title: "Other Items", items: app.otherItems, icon: "ellipsis.circle.fill", color: .gray)
                }
            }
            .padding()
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var appHeader: some View {
        HStack(spacing: 16) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .cornerRadius(12)
                    .shadow(radius: 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.title2)
                    .fontWeight(.bold)

                if let bundleID = app.bundleIdentifier {
                    Text(bundleID)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(app.path.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Grade badge
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(gradeColor.opacity(0.2))
                        .frame(width: 56, height: 56)

                    Text(app.grade.rawValue)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(gradeColor)
                }

                Text("\(app.invasivenessScore)/100")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(gradeColor)
            }
        }
    }

    private var scoreBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Persistence Breakdown")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                BreakdownItem(label: "Launch Agents", count: app.launchAgents.count, points: 8, color: .blue)
                BreakdownItem(label: "Launch Daemons", count: app.launchDaemons.count, points: 15, color: .orange)
                BreakdownItem(label: "Priv Helpers", count: app.privilegedHelpers.count, points: 20, color: .red)
                BreakdownItem(label: "Kernel Ext", count: app.kernelExtensions.count, points: 25, color: .purple)
                BreakdownItem(label: "System Ext", count: app.systemExtensions.count, points: 15, color: .indigo)
                BreakdownItem(label: "Login Items", count: app.loginItems.count, points: 5, color: .green)
            }
        }
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
    }

    private func categorySection(title: String, items: [PersistenceItem], icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.2))
                    .foregroundColor(color)
                    .cornerRadius(4)
            }

            ForEach(items, id: \.identifier) { item in
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundColor(color.opacity(0.6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.system(size: 12, weight: .medium))

                        if let path = item.plistPath?.path {
                            Text(path)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // Trust indicator
                    trustBadge(for: item)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(4)
            }
        }
    }

    private func trustBadge(for item: PersistenceItem) -> some View {
        Group {
            switch item.trustLevel {
            case .apple:
                Label("Apple", systemImage: "apple.logo")
                    .font(.caption2)
                    .foregroundColor(.blue)
            case .knownVendor:
                Label("Signed", systemImage: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
            case .signed:
                Label("Signed", systemImage: "checkmark.seal")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            case .unsigned:
                Label("Unsigned", systemImage: "xmark.seal")
                    .font(.caption2)
                    .foregroundColor(.orange)
            case .suspicious:
                Label("Suspicious", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(.red)
            case .unknown:
                EmptyView()
            }
        }
    }

    private var gradeColor: Color {
        switch app.grade {
        case .clean, .good: return .green
        case .moderate: return .yellow
        case .invasive: return .orange
        case .veryInvasive: return .red
        case .unknown: return .gray
        }
    }
}

// MARK: - Supporting Views

struct StatBadge: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 50)
    }
}

struct BreakdownItem: View {
    let label: String
    let count: Int
    let points: Int
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(count > 0 ? color : .secondary)

            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)

            if count > 0 {
                Text("+\(count * points) pts")
                    .font(.caption2)
                    .foregroundColor(color)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

// MARK: - Text Document for Export

struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let string = String(data: data, encoding: .utf8) {
            text = string
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

import UniformTypeIdentifiers
