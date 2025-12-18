import SwiftUI

/// Settings view for the Persistence Change Monitor
struct MonitoringSettingsView: View {
    @StateObject private var config = MonitorConfiguration.shared
    @StateObject private var monitor = PersistenceMonitor.shared
    @State private var showingResetAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                // Status Section
                statusSection

                // Enable/Disable Toggle
                mainToggleSection

                if config.monitoringEnabled || monitor.isMonitoring {
                    // Settings Sections
                    notificationSettingsSection
                    sensitivitySection
                    categoriesSection
                    baselineSection
                }

                // Presets
                presetsSection

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "eye.circle.fill")
                .font(.title)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading) {
                Text("Real-Time Monitoring")
                    .font(.headline)
                Text("Detect persistence changes as they happen")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.bottom, 5)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        GroupBox {
            HStack {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(monitor.statusDescription)
                    .font(.subheadline)

                Spacer()

                if monitor.isMonitoring {
                    Button("Stop") {
                        monitor.stopMonitoring()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Start") {
                        Task {
                            await monitor.startMonitoring()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if monitor.unacknowledgedCount > 0 {
                Divider()
                HStack {
                    Image(systemName: "bell.badge.fill")
                        .foregroundColor(.orange)
                    Text("\(monitor.unacknowledgedCount) unacknowledged changes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Acknowledge All") {
                        monitor.acknowledgeAllChanges()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var statusColor: Color {
        switch monitor.state {
        case .running:
            return .green
        case .starting, .stopping:
            return .orange
        case .stopped:
            return .gray
        case .error:
            return .red
        }
    }

    // MARK: - Main Toggle

    private var mainToggleSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $config.autoStartMonitoring) {
                    VStack(alignment: .leading) {
                        Text("Auto-start monitoring")
                            .fontWeight(.medium)
                        Text("Start monitoring when the app launches")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Notification Settings

    private var notificationSettingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Notifications")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Toggle("Notify on new items", isOn: $config.notifyOnAdd)
                    .toggleStyle(.switch)

                Toggle("Notify on removed items", isOn: $config.notifyOnRemove)
                    .toggleStyle(.switch)

                Toggle("Notify on modified items", isOn: $config.notifyOnModify)
                    .toggleStyle(.switch)

                Divider()

                Toggle("Play sound for high-priority changes", isOn: $config.playSoundOnHighRelevance)
                    .toggleStyle(.switch)

                Toggle("Show badge on app icon", isOn: $config.showBadge)
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Sensitivity Settings

    private var sensitivitySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sensitivity")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Minimum relevance score")
                        Spacer()
                        Text("\(config.minimumRelevanceScore)")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(config.minimumRelevanceScore) },
                        set: { config.minimumRelevanceScore = Int($0) }
                    ), in: 0...100, step: 5)
                    Text("Only notify for changes with relevance >= \(config.minimumRelevanceScore)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Cooldown interval")
                        Spacer()
                        Text("\(Int(config.cooldownInterval))s")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $config.cooldownInterval, in: 1...30, step: 1)
                    Text("Wait time between checks on the same path")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Categories Section

    private var categoriesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Monitored Categories")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("All") {
                        config.enableAllCategories()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Core") {
                        config.enableCoreOnly()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                ForEach(config.monitorableCategories, id: \.self) { category in
                    Toggle(isOn: Binding(
                        get: { config.enabledCategories.contains(category) },
                        set: { enabled in
                            if enabled {
                                config.enabledCategories.insert(category)
                            } else {
                                config.enabledCategories.remove(category)
                            }
                        }
                    )) {
                        HStack {
                            Image(systemName: category.systemImage)
                                .frame(width: 20)
                                .foregroundColor(.accentColor)
                            Text(category.displayName)
                            if category.requiresFullDiskAccess {
                                Text("FDA")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundColor(.orange)
                                    .cornerRadius(3)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
        }
    }

    // MARK: - Baseline Section

    private var baselineSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Baseline")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                HStack {
                    VStack(alignment: .leading) {
                        Text(monitor.baselineDescription)
                            .font(.subheadline)
                    }

                    Spacer()

                    Button("Update") {
                        Task {
                            try? await monitor.updateBaseline()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Reset") {
                        showingResetAlert = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundColor(.red)
                }

                Text("The baseline is the reference state for detecting changes. Update it after making intentional changes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .alert("Reset Baseline?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                try? monitor.resetBaseline()
            }
        } message: {
            Text("This will clear the baseline and all change history. A new baseline will be created on the next scan.")
        }
    }

    // MARK: - Presets Section

    private var presetsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick Presets")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    ForEach(MonitorConfiguration.Preset.allCases, id: \.self) { preset in
                        Button {
                            config.apply(preset: preset)
                        } label: {
                            VStack {
                                Text(preset.rawValue)
                                    .fontWeight(.medium)
                                Text(preset.description)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    MonitoringSettingsView()
        .frame(width: 500, height: 800)
}
