import SwiftUI

struct ItemDetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if let item = appState.selectedItem {
                ItemDetailContent(item: item)
            } else {
                NoSelectionView()
            }
        }
    }
}

// MARK: - No Selection

struct NoSelectionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Select an Item")
                .font(.title2)
                .fontWeight(.medium)

            Text("Choose an item from the list to view its details")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail Content

struct ItemDetailContent: View {
    let item: PersistenceItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                ItemDetailHeader(item: item)

                Divider()

                // Timeline / Forensics
                TimelineSection(item: item)

                Divider()

                // Risk Assessment
                RiskAssessmentSection(item: item)

                Divider()

                // Signed-but-Dangerous Analysis
                SignedButDangerousSection(item: item)

                Divider()

                // MITRE ATT&CK
                MITRESection(item: item)

                Divider()

                // Trust & Signature
                SignatureSection(item: item)

                Divider()

                // Paths
                PathsSection(item: item)

                if item.category == .launchDaemons || item.category == .launchAgents {
                    Divider()

                    // Launch Configuration
                    LaunchConfigSection(item: item)
                }

                Divider()

                // Actions
                ActionsSection(item: item)
            }
            .padding()
        }
        .navigationTitle(item.name)
    }
}

// MARK: - Header

struct ItemDetailHeader: View {
    let item: PersistenceItem

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Trust badge (large)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(item.trustLevel.color.opacity(0.15))
                    .frame(width: 64, height: 64)

                Image(systemName: item.trustLevel.symbolName)
                    .font(.system(size: 32))
                    .foregroundColor(item.trustLevel.color)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Name
                Text(item.name)
                    .font(.title)
                    .fontWeight(.bold)

                // Identifier
                Text(item.identifier)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)

                // Trust level
                HStack {
                    Text(item.trustLevel.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(item.trustLevel.color)
                        .clipShape(Capsule())

                    Text(item.trustLevel.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Category
                HStack {
                    Image(systemName: item.category.systemImage)
                    Text(item.category.displayName)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Status
            VStack(alignment: .trailing, spacing: 4) {
                StatusBadge(
                    title: item.isLoaded ? "Loaded" : (item.isEnabled ? "Enabled" : "Disabled"),
                    color: item.isLoaded ? .green : (item.isEnabled ? .blue : .secondary)
                )

                if let date = item.plistModifiedAt {
                    Text("Modified: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct StatusBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }
}

// MARK: - Signature Section

struct SignatureSection: View {
    let item: PersistenceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Code Signature", icon: "signature")

            if let sig = item.signatureInfo {
                DetailGrid {
                    DetailRow(label: "Signed", value: sig.isSigned ? "Yes" : "No")
                    DetailRow(label: "Valid", value: sig.isValid ? "Yes" : "No")
                    DetailRow(label: "Apple Signed", value: sig.isAppleSigned ? "Yes" : "No")
                    DetailRow(label: "Notarized", value: sig.isNotarized ? "Yes" : "No")
                    DetailRow(label: "Hardened Runtime", value: sig.hasHardenedRuntime ? "Yes" : "No")

                    if let teamId = sig.teamIdentifier {
                        DetailRow(label: "Team ID", value: teamId, selectable: true)
                    }

                    if let org = sig.organizationName {
                        DetailRow(label: "Organization", value: org)
                    }

                    if let cn = sig.commonName {
                        DetailRow(label: "Common Name", value: cn)
                    }

                    if let expDate = sig.certificateExpirationDate {
                        DetailRow(
                            label: "Cert Expires",
                            value: expDate.formatted(date: .abbreviated, time: .omitted),
                            warning: sig.isCertificateExpired
                        )
                    }

                    if let authority = sig.signingAuthority {
                        DetailRow(label: "Authority", value: authority)
                    }
                }
            } else {
                Text("No signature information available")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Paths Section

struct PathsSection: View {
    let item: PersistenceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Paths", icon: "folder")

            DetailGrid {
                if let plistPath = item.plistPath {
                    DetailRow(label: "Plist", value: plistPath.path, selectable: true, action: {
                        revealInFinder(plistPath)
                    })
                }

                if let execPath = item.executablePath {
                    DetailRow(label: "Executable", value: execPath.path, selectable: true, action: {
                        revealInFinder(execPath)
                    })

                    // Show if executable exists
                    let exists = FileManager.default.fileExists(atPath: execPath.path)
                    DetailRow(
                        label: "Exists",
                        value: exists ? "Yes" : "No",
                        warning: !exists
                    )
                }

                if let parentPath = item.parentAppPath {
                    DetailRow(label: "Parent App", value: parentPath.path, selectable: true, action: {
                        revealInFinder(parentPath)
                    })
                }
            }
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

// MARK: - Launch Config Section

struct LaunchConfigSection: View {
    let item: PersistenceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Launch Configuration", icon: "gearshape.2")

            DetailGrid {
                if let runAtLoad = item.runAtLoad {
                    DetailRow(label: "Run at Load", value: runAtLoad ? "Yes" : "No")
                }

                if let keepAlive = item.keepAlive {
                    DetailRow(label: "Keep Alive", value: keepAlive ? "Yes" : "No")
                }

                if let workDir = item.workingDirectory {
                    DetailRow(label: "Working Dir", value: workDir, selectable: true)
                }

                if let args = item.programArguments, !args.isEmpty {
                    DetailRow(label: "Arguments", value: args.joined(separator: " "), selectable: true)
                }

                if let stdout = item.standardOutPath {
                    DetailRow(label: "Stdout", value: stdout, selectable: true)
                }

                if let stderr = item.standardErrorPath {
                    DetailRow(label: "Stderr", value: stderr, selectable: true)
                }
            }

            if let env = item.environmentVariables, !env.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Environment Variables")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    ForEach(Array(env.keys.sorted()), id: \.self) { key in
                        if let value = env[key] {
                            HStack {
                                Text(key)
                                    .fontWeight(.medium)
                                Text("=")
                                Text(value)
                                    .foregroundColor(.secondary)
                            }
                            .font(.caption)
                            .textSelection(.enabled)
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - Actions Section

struct ActionsSection: View {
    let item: PersistenceItem
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showNoPathAlert = false
    @State private var showDisableError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Actions", icon: "hand.tap")

            HStack(spacing: 12) {
                Button {
                    revealInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .disabled(!hasRevealablePath)

                if item.plistPath != nil {
                    Button {
                        openPlist()
                    } label: {
                        Label("Open Plist", systemImage: "doc.text")
                    }
                }

                // Graph button
                Button {
                    appState.focusedGraphItem = item
                    openWindow(id: "graph-window")
                } label: {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.bordered)
                .tint(.purple)

                Spacer()

                if canDisable {
                    if item.isEnabled {
                        Button(role: .destructive) {
                            disableItem()
                        } label: {
                            Label("Disable", systemImage: "xmark.circle")
                        }
                    } else {
                        Button {
                            enableItem()
                        } label: {
                            Label("Enable", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .alert("No Path Available", isPresented: $showNoPathAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This item doesn't have a file path to reveal in Finder.")
        }
        .alert("Action Failed", isPresented: $showDisableError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private var hasRevealablePath: Bool {
        item.plistPath != nil || item.executablePath != nil
    }

    private var canDisable: Bool {
        // Allow disable for items with plist files or executable paths
        // LaunchDaemons/Agents: rename plist
        // Other categories: rename executable or config file
        if item.plistPath != nil {
            return true
        }
        if item.executablePath != nil {
            // Allow disable for scripts and plugins
            switch item.category {
            case .periodicScripts, .shellStartupFiles, .authorizationPlugins,
                 .spotlightImporters, .quickLookPlugins, .directoryServicesPlugins:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func revealInFinder() {
        // Try plist first, then executable
        if let plistPath = item.plistPath {
            NSWorkspace.shared.selectFile(plistPath.path, inFileViewerRootedAtPath: plistPath.deletingLastPathComponent().path)
            return
        }
        if let execPath = item.executablePath {
            NSWorkspace.shared.selectFile(execPath.path, inFileViewerRootedAtPath: execPath.deletingLastPathComponent().path)
            return
        }
        showNoPathAlert = true
    }

    private func openPlist() {
        if let plistPath = item.plistPath {
            NSWorkspace.shared.open(plistPath)
        }
    }

    private var requiresAdmin: Bool {
        // Check plist path first, then executable path
        if let path = item.plistPath?.path {
            return path.hasPrefix("/Library/") || path.hasPrefix("/System/")
        }
        if let path = item.executablePath?.path {
            return path.hasPrefix("/Library/") || path.hasPrefix("/System/") || path.hasPrefix("/etc/") || path.hasPrefix("/usr/")
        }
        return false
    }

    /// Get the target path for disable/enable operations
    private var targetPath: URL? {
        // Prefer plist for LaunchDaemons/Agents
        if let plistPath = item.plistPath {
            return plistPath
        }
        // Use executable path for scripts and plugins
        if let execPath = item.executablePath {
            return execPath
        }
        return nil
    }

    private func disableItem() {
        guard let targetPath = targetPath else { return }

        Task {
            do {
                let disabledPath = targetPath.appendingPathExtension("disabled")

                if requiresAdmin {
                    // Use AppleScript for privileged operation
                    let script = """
                        do shell script "mv '\(targetPath.path)' '\(disabledPath.path)'" with administrator privileges
                        """

                    let result = try await runAppleScript(script)
                    if !result.success {
                        throw NSError(domain: "DisableError", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error ?? "Admin operation failed"])
                    }
                } else {
                    // Regular file move for user-level items
                    try FileManager.default.moveItem(at: targetPath, to: disabledPath)
                }

                // Unload from launchctl if loaded (only for LaunchDaemons/Agents)
                if item.isLoaded && item.plistPath != nil {
                    if requiresAdmin {
                        let unloadScript = """
                            do shell script "launchctl bootout system '\(targetPath.path)' 2>/dev/null || true" with administrator privileges
                            """
                        _ = try? await runAppleScript(unloadScript)
                    } else {
                        let domain = "gui/\(getuid())"
                        _ = await CommandRunner.run("/bin/launchctl", arguments: ["bootout", domain, targetPath.path], timeout: 5.0)
                    }
                }

                // Record in database
                try DatabaseManager.shared.recordDisabledItem(
                    originalPath: targetPath.path,
                    safePath: disabledPath.path,
                    identifier: item.identifier,
                    category: item.category,
                    method: "rename",
                    plistContent: nil,
                    wasLoaded: item.isLoaded
                )

                // Refresh scan
                await appState.scan(category: item.category)
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to disable: \(error.localizedDescription)"
                    showDisableError = true
                }
            }
        }
    }

    private func enableItem() {
        guard let targetPath = targetPath else { return }

        Task {
            do {
                // The disabled file has .disabled extension
                let disabledPath = URL(fileURLWithPath: targetPath.path + ".disabled")

                // Check if the disabled file exists
                guard FileManager.default.fileExists(atPath: disabledPath.path) else {
                    await MainActor.run {
                        errorMessage = "Cannot find disabled file at: \(disabledPath.path)"
                        showDisableError = true
                    }
                    return
                }

                if requiresAdmin {
                    let script = """
                        do shell script "mv '\(disabledPath.path)' '\(targetPath.path)'" with administrator privileges
                        """
                    let result = try await runAppleScript(script)
                    if !result.success {
                        throw NSError(domain: "EnableError", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error ?? "Admin operation failed"])
                    }
                } else {
                    try FileManager.default.moveItem(at: disabledPath, to: targetPath)
                }

                // Remove database record if exists
                try? DatabaseManager.shared.removeDisabledItemRecord(identifier: item.identifier)

                // Refresh scan
                await appState.scan(category: item.category)
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to enable: \(error.localizedDescription)"
                    showDisableError = true
                }
            }
        }
    }

    private func runAppleScript(_ source: String) async throws -> (success: Bool, error: String?) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                script?.executeAndReturnError(&error)

                if let error = error {
                    let errorMsg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                    continuation.resume(returning: (false, errorMsg))
                } else {
                    continuation.resume(returning: (true, nil))
                }
            }
        }
    }
}

// MARK: - MITRE ATT&CK Section

struct MITRESection: View {
    let item: PersistenceItem

    private var techniques: [MITRETechnique] {
        item.category.mitreTechniques
    }

    private var tactics: [MITRETactic] {
        item.category.mitreTactics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "MITRE ATT&CK", icon: "shield.lefthalf.filled")

            // Tactics
            if !tactics.isEmpty {
                HStack(spacing: 8) {
                    Text("Tactics:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(tactics, id: \.self) { tactic in
                        TacticBadge(tactic: tactic)
                    }
                }
            }

            // Techniques
            VStack(alignment: .leading, spacing: 8) {
                ForEach(techniques) { technique in
                    TechniqueRow(technique: technique)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            // Link to MITRE ATT&CK
            if let primaryTechnique = techniques.first {
                Link(destination: primaryTechnique.url) {
                    HStack {
                        Image(systemName: "arrow.up.right.square")
                        Text("View on MITRE ATT&CK")
                    }
                    .font(.caption)
                }
            }
        }
    }
}

struct TacticBadge: View {
    let tactic: MITRETactic

    private var color: Color {
        switch tactic {
        case .persistence: return .purple
        case .privilegeEscalation: return .red
        case .defenseEvasion: return .orange
        case .execution: return .blue
        case .credentialAccess: return .yellow
        case .discovery: return .green
        case .collection: return .teal
        }
    }

    var body: some View {
        Text(tactic.rawValue)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color)
            .clipShape(Capsule())
    }
}

struct TechniqueRow: View {
    let technique: MITRETechnique
    @State private var isHovered = false

    var body: some View {
        Link(destination: technique.url) {
            HStack(spacing: 12) {
                // Technique ID
                Text(technique.id)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.purple)
                    .frame(width: 80, alignment: .leading)

                // Technique Name
                VStack(alignment: .leading, spacing: 2) {
                    Text(technique.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(technique.description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // Link indicator
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}

// MARK: - Timeline Section

struct TimelineSection: View {
    let item: PersistenceItem

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Timeline & Forensics", icon: "clock.arrow.circlepath")

            VStack(spacing: 0) {
                // Always show discovery info first
                TimelineGroupHeader(title: "Discovery", icon: "magnifyingglass")

                TimelineRow(
                    label: "First Seen",
                    date: item.discoveredAt,
                    icon: "eye.circle",
                    color: .purple,
                    dateFormatter: dateFormatter,
                    relativeDateFormatter: relativeDateFormatter
                )

                // Plist timestamps
                if item.plistCreatedAt != nil || item.plistModifiedAt != nil {
                    TimelineGroupHeader(title: "Configuration File", icon: "doc.text")

                    if let created = item.plistCreatedAt {
                        TimelineRow(
                            label: "Created",
                            date: created,
                            icon: "plus.circle",
                            color: .green,
                            dateFormatter: dateFormatter,
                            relativeDateFormatter: relativeDateFormatter
                        )
                    }

                    if let modified = item.plistModifiedAt {
                        TimelineRow(
                            label: "Modified",
                            date: modified,
                            icon: "pencil.circle",
                            color: .orange,
                            dateFormatter: dateFormatter,
                            relativeDateFormatter: relativeDateFormatter
                        )
                    }
                }

                // Binary timestamps
                if item.binaryCreatedAt != nil || item.binaryModifiedAt != nil || item.binaryLastExecutedAt != nil {
                    TimelineGroupHeader(title: "Executable", icon: "terminal")

                    if let created = item.binaryCreatedAt {
                        TimelineRow(
                            label: "Created",
                            date: created,
                            icon: "plus.circle",
                            color: .green,
                            dateFormatter: dateFormatter,
                            relativeDateFormatter: relativeDateFormatter
                        )
                    }

                    if let modified = item.binaryModifiedAt {
                        TimelineRow(
                            label: "Modified",
                            date: modified,
                            icon: "pencil.circle",
                            color: .orange,
                            dateFormatter: dateFormatter,
                            relativeDateFormatter: relativeDateFormatter
                        )
                    }

                    if let executed = item.binaryLastExecutedAt {
                        TimelineRow(
                            label: "Last Executed",
                            date: executed,
                            icon: "play.circle",
                            color: .blue,
                            dateFormatter: dateFormatter,
                            relativeDateFormatter: relativeDateFormatter,
                            highlight: isRecentExecution(executed)
                        )
                    }
                }

                // Network activity
                if item.networkFirstSeenAt != nil || item.networkLastSeenAt != nil {
                    TimelineGroupHeader(title: "Network Activity", icon: "network")

                    if let firstSeen = item.networkFirstSeenAt {
                        TimelineRow(
                            label: "First Connection",
                            date: firstSeen,
                            icon: "arrow.up.circle",
                            color: .cyan,
                            dateFormatter: dateFormatter,
                            relativeDateFormatter: relativeDateFormatter
                        )
                    }

                    if let lastSeen = item.networkLastSeenAt {
                        TimelineRow(
                            label: "Last Connection",
                            date: lastSeen,
                            icon: "arrow.down.circle",
                            color: .cyan,
                            dateFormatter: dateFormatter,
                            relativeDateFormatter: relativeDateFormatter
                        )
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            // Anomaly detection
            let anomalies = FileTimestampExtractor.shared.checkForSuspiciousTimestamps(item: item)
            if !anomalies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Timestamp Anomalies Detected")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }

                    ForEach(anomalies) { anomaly in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(anomalyColor(anomaly.severity))
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)

                            Text(anomaly.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }

    private func isRecentExecution(_ date: Date) -> Bool {
        Date().timeIntervalSince(date) < 3600 // Last hour
    }

    private func anomalyColor(_ severity: FileTimestampExtractor.TimestampAnomaly.Severity) -> Color {
        switch severity {
        case .low: return .blue
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }
}

struct TimelineGroupHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

struct TimelineRow: View {
    let label: String
    let date: Date
    let icon: String
    let color: Color
    let dateFormatter: DateFormatter
    let relativeDateFormatter: RelativeDateTimeFormatter
    var highlight: Bool = false

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(dateFormatter.string(from: date))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(highlight ? .orange : .primary)

            Spacer()

            Text(relativeDateFormatter.localizedString(for: date, relativeTo: Date()))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
        .background(highlight ? Color.orange.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}

// MARK: - Signed-but-Dangerous Section

struct SignedButDangerousSection: View {
    let item: PersistenceItem
    @State private var analysisResult: SignedButDangerousAnalyzer.AnalysisResult?
    @State private var isAnalyzing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Signed-but-Dangerous Analysis", icon: "checkmark.shield.fill")

                Spacer()

                if isAnalyzing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button {
                        runAnalysis()
                    } label: {
                        Label("Analyze", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let result = analysisResult {
                // Overall risk badge
                HStack(spacing: 12) {
                    RiskLevelBadge(level: result.overallRisk)

                    Text(result.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Flags list
                if !result.flags.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(result.flags) { flag in
                            SignedDangerousFlagRow(flag: flag)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(8)
                } else if item.signatureInfo?.isSigned == true {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("No suspicious indicators detected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
            } else if item.signatureInfo?.isSigned != true {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("Only applicable to signed binaries")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                    Text("Click 'Analyze' to check for signed-but-dangerous indicators")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            // Auto-analyze if signed
            if item.signatureInfo?.isSigned == true && analysisResult == nil {
                runAnalysis()
            }
        }
    }

    private func runAnalysis() {
        isAnalyzing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SignedButDangerousAnalyzer.shared.analyze(item: item)
            DispatchQueue.main.async {
                self.analysisResult = result
                self.isAnalyzing = false
            }
        }
    }
}

struct RiskLevelBadge: View {
    let level: SignedButDangerousAnalyzer.AnalysisResult.RiskLevel

    private var color: Color {
        switch level {
        case .safe: return .green
        case .lowRisk: return .blue
        case .suspicious: return .yellow
        case .dangerous: return .orange
        case .critical: return .red
        }
    }

    private var icon: String {
        switch level {
        case .safe: return "checkmark.shield"
        case .lowRisk: return "shield"
        case .suspicious: return "exclamationmark.shield"
        case .dangerous: return "exclamationmark.triangle"
        case .critical: return "xmark.shield"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(level.rawValue)
        }
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color)
        .clipShape(Capsule())
    }
}

struct SignedDangerousFlagRow: View {
    let flag: SignedButDangerousAnalyzer.DangerFlag

    private var severityColor: Color {
        switch flag.severity {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        case .info: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Severity/Points badge
            Text("+\(flag.points)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(severityColor)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(flag.title)
                        .font(.caption)
                        .fontWeight(.semibold)

                    Text("[\(flag.severity.rawValue)]")
                        .font(.system(size: 9))
                        .foregroundColor(severityColor)
                }

                Text(flag.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}

// MARK: - Risk Assessment Section

struct RiskAssessmentSection: View {
    let item: PersistenceItem

    private var severity: RiskScorer.RiskSeverity {
        .from(score: item.riskScore ?? 0)
    }

    private var color: Color {
        switch severity {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Risk Assessment", icon: "exclamationmark.triangle")

            // Score display
            HStack(spacing: 16) {
                // Large score badge
                ZStack {
                    Circle()
                        .stroke(color.opacity(0.3), lineWidth: 8)
                        .frame(width: 80, height: 80)

                    Circle()
                        .trim(from: 0, to: CGFloat(item.riskScore ?? 0) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 2) {
                        Text("\(item.riskScore ?? 0)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(color)
                        Text("/100")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    // Severity badge
                    Text(severity.rawValue)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(color)
                        .clipShape(Capsule())

                    // Description
                    Text(severityDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            // Risk factors
            if let details = item.riskDetails, !details.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Risk Factors")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)

                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        RiskFactorRow(detail: detail)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            } else if (item.riskScore ?? 0) == 0 {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("No risk factors detected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }

    private var severityDescription: String {
        switch severity {
        case .low:
            return "This item appears safe with no significant risk indicators."
        case .medium:
            return "Some risk factors detected. Review the details below."
        case .high:
            return "Multiple risk factors present. Investigate this item carefully."
        case .critical:
            return "High-risk item! Strongly recommend investigation."
        }
    }
}

struct RiskFactorRow: View {
    let detail: RiskScorer.RiskDetail

    private var color: Color {
        switch detail.points {
        case 0..<15: return .yellow
        case 15..<25: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Points badge
            Text("+\(detail.points)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color)
                .clipShape(Capsule())

            // Factor name
            Text(detail.factor)
                .font(.caption)
                .fontWeight(.medium)

            // Description
            Text("- \(detail.description)")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}

// MARK: - Helper Views

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.headline)
    }
}

struct DetailGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), alignment: .leading)
        ], spacing: 8) {
            content
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var selectable: Bool = false
    var warning: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            if let action = action {
                Button(action: action) {
                    Text(value)
                        .font(.caption)
                        .foregroundColor(warning ? .red : .primary)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            } else {
                Group {
                    if selectable {
                        Text(value)
                            .textSelection(.enabled)
                    } else {
                        Text(value)
                    }
                }
                .font(.caption)
                .foregroundColor(warning ? .red : .primary)
                .multilineTextAlignment(.leading)
            }

            Spacer()
        }
    }
}

#Preview {
    ItemDetailView()
        .environmentObject(AppState.shared)
}
