import SwiftUI

struct PermissionGuideView: View {
    @EnvironmentObject var fdaChecker: FullDiskAccessChecker
    @EnvironmentObject var appState: AppState
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            contentView

            Divider()

            // Footer
            footerView
        }
        .frame(width: 600, height: 500)
        .onAppear {
            // Auto-open System Settings immediately
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                fdaChecker.openSystemSettings()
                currentStep = 1
            }

            fdaChecker.startPolling {
                // Permission granted, view will automatically dismiss
            }
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

            Spacer()

            // Status indicator
            statusView
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

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Button("Skip for now") {
                appState.skipFDACheck = true
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

#Preview {
    PermissionGuideView()
        .environmentObject(FullDiskAccessChecker.shared)
        .environmentObject(AppState.shared)
}
