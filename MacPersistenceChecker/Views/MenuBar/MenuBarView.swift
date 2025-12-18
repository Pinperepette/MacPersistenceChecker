import SwiftUI

/// Menu Bar Extra view for quick monitoring control
struct MenuBarView: View {
    @ObservedObject var monitor: PersistenceMonitor
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with status
            HStack {
                Circle()
                    .fill(monitor.isMonitoring ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(monitor.isMonitoring ? "Monitoring Active" : "Monitoring Off")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Stats when monitoring
            if monitor.isMonitoring {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "eye.fill")
                            .foregroundColor(.green)
                            .frame(width: 20)
                        Text("Watching \(monitor.statusDescription.replacingOccurrences(of: "Monitoring ", with: ""))")
                            .font(.subheadline)
                    }

                    if monitor.changeCount > 0 {
                        HStack {
                            Image(systemName: "bell.badge.fill")
                                .foregroundColor(.orange)
                                .frame(width: 20)
                            Text("\(monitor.changeCount) changes detected")
                                .font(.subheadline)
                        }
                    }

                    if monitor.unacknowledgedCount > 0 {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                                .frame(width: 20)
                            Text("\(monitor.unacknowledgedCount) unacknowledged")
                                .font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()
            }

            // Toggle button
            Button(action: {
                Task {
                    await monitor.toggleMonitoring()
                }
            }) {
                HStack {
                    Image(systemName: monitor.isMonitoring ? "stop.fill" : "play.fill")
                        .foregroundColor(monitor.isMonitoring ? .red : .green)
                        .frame(width: 20)
                    Text(monitor.isMonitoring ? "Stop Monitoring" : "Start Monitoring")
                    Spacer()
                    Text(monitor.isMonitoring ? "⌘S" : "⌘M")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Quick scan
            Button(action: {
                Task {
                    await appState.scanAll()
                }
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 20)
                    Text("Scan Now")
                    Spacer()
                    if appState.isScanning {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(appState.isScanning)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Last change info
            if let lastChange = monitor.lastChange {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Change")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        Image(systemName: lastChange.type.iconName)
                            .foregroundColor(lastChange.type.color)
                            .frame(width: 16)
                        Text(lastChange.item?.name ?? "Unknown")
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            // Open main window
            Button(action: {
                NSApplication.shared.activate(ignoringOtherApps: true)
                // Find and show the main window (not menu bar window)
                for window in NSApplication.shared.windows {
                    if window.canBecomeMain && !window.title.isEmpty {
                        window.makeKeyAndOrderFront(nil)
                        break
                    }
                }
                // If no window found, create one by opening the app
                if NSApplication.shared.windows.filter({ $0.canBecomeMain }).isEmpty {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/MacPersistenceChecker.app"))
                }
            }) {
                HStack {
                    Image(systemName: "macwindow")
                        .frame(width: 20)
                    Text("Open MacPersistenceChecker")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Quit
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack {
                    Image(systemName: "power")
                        .frame(width: 20)
                    Text("Quit")
                    Spacer()
                    Text("⌘Q")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 260)
    }
}

// MARK: - Menu Bar Icon

extension MonitorChangeType {
    var iconName: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .enabled: return "checkmark.circle.fill"
        case .disabled: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .added: return .green
        case .removed: return .red
        case .modified: return .orange
        case .enabled: return .blue
        case .disabled: return .gray
        }
    }
}
