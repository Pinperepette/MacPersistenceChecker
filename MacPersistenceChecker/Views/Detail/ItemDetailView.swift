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
        // Only allow disable for items with plist files (LaunchDaemons/Agents)
        item.plistPath != nil && (item.category == .launchDaemons || item.category == .launchAgents)
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
        guard let path = item.plistPath?.path else { return false }
        // System paths require admin
        return path.hasPrefix("/Library/") || path.hasPrefix("/System/")
    }

    private func disableItem() {
        guard let plistPath = item.plistPath else { return }

        Task {
            do {
                let disabledPath = plistPath.appendingPathExtension("disabled")

                if requiresAdmin {
                    // Use AppleScript for privileged operation
                    let script = """
                        do shell script "mv '\(plistPath.path)' '\(disabledPath.path)'" with administrator privileges
                        """

                    let result = try await runAppleScript(script)
                    if !result.success {
                        throw NSError(domain: "DisableError", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error ?? "Admin operation failed"])
                    }
                } else {
                    // Regular file move for user-level items
                    try FileManager.default.moveItem(at: plistPath, to: disabledPath)
                }

                // Unload from launchctl if loaded (may need admin too)
                if item.isLoaded {
                    if requiresAdmin {
                        let unloadScript = """
                            do shell script "launchctl bootout system '\(plistPath.path)' 2>/dev/null || true" with administrator privileges
                            """
                        _ = try? await runAppleScript(unloadScript)
                    } else {
                        let domain = "gui/\(getuid())"
                        _ = await CommandRunner.run("/bin/launchctl", arguments: ["bootout", domain, plistPath.path], timeout: 5.0)
                    }
                }

                // Record in database
                try DatabaseManager.shared.recordDisabledItem(
                    originalPath: plistPath.path,
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
        guard let plistPath = item.plistPath else { return }

        Task {
            do {
                // The disabled file has .disabled extension
                let disabledPath = URL(fileURLWithPath: plistPath.path + ".disabled")

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
                        do shell script "mv '\(disabledPath.path)' '\(plistPath.path)'" with administrator privileges
                        """
                    let result = try await runAppleScript(script)
                    if !result.success {
                        throw NSError(domain: "EnableError", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error ?? "Admin operation failed"])
                    }
                } else {
                    try FileManager.default.moveItem(at: disabledPath, to: plistPath)
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
