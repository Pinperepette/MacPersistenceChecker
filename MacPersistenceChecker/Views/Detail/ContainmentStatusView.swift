import SwiftUI

// MARK: - Containment Status Banner

/// Prominent banner showing containment status with full transparency
struct ContainmentStatusBanner: View {
    let status: ContainmentState
    let item: PersistenceItem
    let onExtend: () -> Void
    let onRelease: () -> Void
    let onViewLog: () -> Void

    @State private var showingLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundColor(.orange)

                Text("CONTAINED")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)

                Spacer()

                // Time remaining
                Text(status.timeRemaining)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }

            Divider()
                .background(Color.orange.opacity(0.3))

            // Containment details - full transparency
            VStack(alignment: .leading, spacing: 10) {
                // Persistence status
                if status.persistenceDisabled {
                    ContainmentDetailRow(
                        icon: "doc.badge.gearshape.fill",
                        iconColor: .blue,
                        title: "Persistence Disabled",
                        detail: "Plist renamed to .contained",
                        isActive: true
                    )
                }

                // Network status
                if status.networkBlocked, let rule = status.networkRule {
                    ContainmentDetailRow(
                        icon: "network.slash",
                        iconColor: .red,
                        title: "Network Blocked",
                        detail: "Anchor: \(rule.anchor)",
                        isActive: true
                    )

                    // Show actual rule
                    Text("Rule: block drop out quick all")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.leading, 28)

                    // Method used
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                            .font(.caption2)
                        Text("Method: \(rule.method.rawValue)")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                    .padding(.leading, 28)

                    // Expiration countdown
                    if let expires = rule.expiresAt {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption)
                            Text("Expires: \(expires, style: .relative)")
                                .font(.caption)
                        }
                        .foregroundColor(.orange)
                        .padding(.leading, 28)
                    }
                }

                // Binary integrity
                if let hash = status.binaryHash {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("Binary Hash:")
                            .font(.caption)
                        Text(hash.prefix(24) + "...")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                // Containment time
                if let containedAt = status.containedAt {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundColor(.secondary)
                        Text("Contained:")
                            .font(.caption)
                        Text(containedAt, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("ago")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()
                .background(Color.orange.opacity(0.3))

            // Action buttons
            HStack(spacing: 12) {
                Button(action: onViewLog) {
                    Label("View Log", systemImage: "list.bullet.rectangle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Spacer()

                Button(action: onExtend) {
                    Label("Extend 24h", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onRelease) {
                    Label("Release", systemImage: "lock.open")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange, lineWidth: 2)
        )
    }
}

// MARK: - Containment Detail Row

struct ContainmentDetailRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let detail: String
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(isActive ? iconColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Containment Menu

/// Dropdown menu for containment actions
struct ContainmentMenu: View {
    let item: PersistenceItem
    @ObservedObject var containmentService: SafeContainmentService
    let onActionComplete: (ContainmentResult) -> Void

    @State private var isProcessing = false
    @State private var showConfirmation = false
    @State private var pendingAction: ContainmentAction? = nil

    private var isContained: Bool {
        containmentService.isContained(item.identifier)
    }

    private var containmentState: ContainmentState {
        containmentService.getContainmentState(for: item.identifier)
    }

    var body: some View {
        Menu {
            if !isContained {
                // Containment options
                Button {
                    Task { await performDisablePersistence() }
                } label: {
                    Label("Disable Persistence Only", systemImage: "doc.badge.gearshape")
                }

                Button {
                    Task { await performBlockNetwork() }
                } label: {
                    Label("Block Network Only", systemImage: "network.slash")
                }

                Divider()

                Button {
                    Task { await performFullContainment() }
                } label: {
                    Label("Full Containment", systemImage: "lock.shield")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

            } else {
                // Release options
                Button {
                    Task { await performExtendTimeout() }
                } label: {
                    Label("Extend 24 Hours", systemImage: "clock.arrow.circlepath")
                }

                Divider()

                Button(role: .destructive) {
                    Task { await performRelease() }
                } label: {
                    Label("Release Item", systemImage: "lock.open")
                }
            }

        } label: {
            HStack(spacing: 6) {
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: isContained ? "lock.shield.fill" : "lock.shield")
                }
                Text(isContained ? "Contained" : "Contain")
                    .fontWeight(.medium)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isContained ? Color.orange : Color.red)
            .cornerRadius(8)
        }
        .disabled(isProcessing)
    }

    // MARK: - Actions

    private func performDisablePersistence() async {
        isProcessing = true
        let result = await containmentService.disablePersistenceOnly(item)
        await MainActor.run {
            isProcessing = false
            onActionComplete(result)
        }
    }

    private func performBlockNetwork() async {
        isProcessing = true
        let result = await containmentService.blockNetworkOnly(item)
        await MainActor.run {
            isProcessing = false
            onActionComplete(result)
        }
    }

    private func performFullContainment() async {
        isProcessing = true
        let result = await containmentService.containItem(item)
        await MainActor.run {
            isProcessing = false
            onActionComplete(result)
        }
    }

    private func performExtendTimeout() async {
        isProcessing = true
        let result = await containmentService.extendTimeout(item)
        await MainActor.run {
            isProcessing = false
            onActionComplete(result)
        }
    }

    private func performRelease() async {
        isProcessing = true
        let result = await containmentService.releaseItem(item)
        await MainActor.run {
            isProcessing = false
            onActionComplete(result)
        }
    }
}

// MARK: - Action Log View

struct ContainmentActionLogView: View {
    let item: PersistenceItem
    @ObservedObject var containmentService: SafeContainmentService

    private var actions: [ContainmentAction] {
        containmentService.getActionHistory(for: item.identifier)
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundColor(.accentColor)
                Text("Action Log")
                    .font(.headline)
                Spacer()
                Text("\(actions.count) actions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            if actions.isEmpty {
                Text("No containment actions recorded")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(actions, id: \.id) { action in
                            ActionLogRow(action: action, dateFormatter: dateFormatter)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}

struct ActionLogRow: View {
    let action: ContainmentAction
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                // Action type
                HStack {
                    Text(action.displayDescription)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Spacer()

                    Text(statusText)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.2))
                        .foregroundColor(statusColor)
                        .cornerRadius(4)
                }

                // Timestamp
                Text(dateFormatter.string(from: action.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Details
                if let anchor = action.networkAnchor {
                    Text("Anchor: \(anchor)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let expires = action.expiresAt {
                    Text("Expires: \(dateFormatter.string(from: expires))")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }

    private var statusColor: Color {
        switch action.status {
        case .active: return .orange
        case .released: return .green
        case .expired: return .gray
        case .failed: return .red
        case .partial: return .yellow
        }
    }

    private var statusText: String {
        switch action.status {
        case .active: return "Active"
        case .released: return "Released"
        case .expired: return "Expired"
        case .failed: return "Failed"
        case .partial: return "Partial"
        }
    }
}

// MARK: - Confirmation Dialog

struct ContainmentConfirmationDialog: View {
    let item: PersistenceItem
    let actionType: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Confirm \(actionType)")
                .font(.headline)

            Text("This will \(actionDescription) for:\n\(item.name)")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(actionType, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 300)
    }

    private var actionDescription: String {
        switch actionType.lowercased() {
        case "full containment":
            return "disable persistence and block network"
        case "disable persistence":
            return "rename the plist to prevent loading"
        case "block network":
            return "block all network traffic from this binary"
        case "release":
            return "restore the item to its original state"
        default:
            return "perform the selected action"
        }
    }
}
