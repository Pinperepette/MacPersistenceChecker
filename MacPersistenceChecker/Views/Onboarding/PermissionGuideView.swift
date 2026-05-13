import SwiftUI

struct PermissionGuideView: View {
    @EnvironmentObject var fdaChecker: FullDiskAccessChecker
    @EnvironmentObject var appState: AppState
    @State private var currentStep = 0
    @State private var signingStatusSummary = "Signing: checking..."

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                contentView
            }

            Divider()

            // Footer
            footerView
        }
        .frame(width: 680, height: 640)
        .onAppear {
            // Auto-open System Settings immediately
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                fdaChecker.openSystemSettings()
                currentStep = 1
            }

            fdaChecker.startPolling {
                // Permission granted, view will automatically dismiss
            }
            loadSigningStatus()
        }
        .onDisappear {
            fdaChecker.stopPolling()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("MacPersistenceChecker")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Full Disk Access Required")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 32)
    }

    // MARK: - Content

    private var contentView: some View {
        VStack(spacing: 24) {
            // Explanation
            VStack(alignment: .leading, spacing: 12) {
                Text("Why is this needed?")
                    .font(.headline)

                Text("To scan all persistence mechanisms on your Mac, including Launch Daemons and system-level configurations, MacPersistenceChecker needs Full Disk Access permission.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal)

            // Steps
            VStack(alignment: .leading, spacing: 16) {
                Text("How to enable:")
                    .font(.headline)

                StepView(
                    number: 1,
                    title: "Open System Settings",
                    description: "Click the button below to open Privacy settings",
                    isActive: currentStep == 0
                )

                StepView(
                    number: 2,
                    title: "Find Full Disk Access",
                    description: "Navigate to Privacy & Security > Full Disk Access",
                    isActive: currentStep == 1
                )

                StepView(
                    number: 3,
                    title: "Enable MacPersistenceChecker",
                    description: "Click the + button and add MacPersistenceChecker, or toggle it on if already listed",
                    isActive: currentStep == 2
                )
            }
            .padding(.horizontal)

            // Status indicator
            statusView

            diagnosticDisclosure
        }
        .padding()
    }

    private var statusView: some View {
        HStack(spacing: 12) {
            if fdaChecker.isChecking {
                ProgressView()
                    .scaleEffect(0.8)

                Text("Waiting for permission...")
                    .foregroundColor(.secondary)
            } else if fdaChecker.hasFullDiskAccess {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)

                Text("Permission granted!")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)

                Text("Permission not yet granted")
                    .foregroundColor(.orange)
            }
        }
        .font(.callout)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }

    private var diagnosticDisclosure: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(signingStatusSummary)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)

                if let snapshot = fdaChecker.lastSnapshot {
                    Text("Last refresh: \(snapshot.reason.rawValue), granted: \(snapshot.isGranted ? "yes" : "no")")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(snapshot.results, id: \.probeID) { result in
                        Text(result.diagnosticSummary)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    Text("No FDA probe snapshot has been recorded yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !fdaChecker.hasFullDiskAccess {
                    Label("Restart may be required by macOS after changing this permission.", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Diagnostic Details")
                .font(.callout)
                .fontWeight(.medium)
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Continue without Full Disk Access") {
                fdaChecker.stopPolling()
                appState.skipFDACheckForCurrentSession = true
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Spacer()

            Button {
                fdaChecker.openSystemSettings()
                currentStep = 1
            } label: {
                Label("Open System Settings", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func loadSigningStatus() {
        let bundlePath = Bundle.main.bundlePath

        Task.detached {
            let summary = AppSigningStatus.summary(for: bundlePath)
            await MainActor.run {
                signingStatusSummary = summary
            }
        }
    }
}

// MARK: - Step View

struct StepView: View {
    let number: Int
    let title: String
    let description: String
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Number circle
            ZStack {
                Circle()
                    .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 28, height: 28)

                Text("\(number)")
                    .font(.callout)
                    .fontWeight(.bold)
                    .foregroundColor(isActive ? .white : .secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(isActive ? .primary : .secondary)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private enum AppSigningStatus {
    static func summary(for bundlePath: String) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvvv", "-r-", bundlePath]
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Signing: unavailable (\(error.localizedDescription))"
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)

        let signature = value(for: "Signature", in: output) ?? "unknown"
        let teamIdentifier = value(for: "TeamIdentifier", in: output) ?? "unknown"
        let requirement: String
        if output.contains("designated => cdhash") {
            requirement = "requirement=cdhash-only"
        } else if output.contains("designated =>") {
            requirement = "requirement=stable"
        } else {
            requirement = "requirement=unknown"
        }

        return "Signing: Signature=\(signature); TeamIdentifier=\(teamIdentifier); \(requirement)"
    }

    private static func value(for key: String, in output: String) -> String? {
        guard let line = output
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("\(key)=") }) else {
            return nil
        }

        return String(line.dropFirst(key.count + 1))
    }
}

#if XCODE_PREVIEWS
#Preview {
    PermissionGuideView()
        .environmentObject(FullDiskAccessChecker.shared)
        .environmentObject(AppState.shared)
}
#endif
