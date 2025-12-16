import SwiftUI

@main
struct MacPersistenceCheckerApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var fdaChecker = FullDiskAccessChecker.shared

    init() {
        // Initialize database
        do {
            try DatabaseManager.shared.initialize()
        } catch {
            print("Failed to initialize database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if fdaChecker.hasFullDiskAccess || appState.skipFDACheck {
                    ContentView()
                        .environmentObject(appState)
                } else {
                    PermissionGuideView()
                        .environmentObject(fdaChecker)
                        .environmentObject(appState)
                }
            }
            .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ScanSettingsView()
                .tabItem {
                    Label("Scanning", systemImage: "magnifyingglass")
                }

            ExtendedScannersSettingsView()
                .tabItem {
                    Label("Extended Scanners", systemImage: "plus.circle")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 550, height: 500)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autoScanOnLaunch") private var autoScanOnLaunch = true
    @AppStorage("showNotifications") private var showNotifications = true

    var body: some View {
        Form {
            Toggle("Scan automatically on launch", isOn: $autoScanOnLaunch)
            Toggle("Show notifications for new items", isOn: $showNotifications)
        }
        .padding()
    }
}

struct ScanSettingsView: View {
    @AppStorage("includeSystemItems") private var includeSystemItems = true
    @AppStorage("verifySignatures") private var verifySignatures = true

    var body: some View {
        Form {
            Section {
                Toggle("Include system items", isOn: $includeSystemItems)
                Toggle("Verify code signatures", isOn: $verifySignatures)
            } header: {
                Text("Core Scanners")
            } footer: {
                Text("Core scanners check: Launch Daemons/Agents, Login Items, Kernel/System Extensions, Privileged Helpers, Cron Jobs, MDM Profiles, and Application Support.")
            }
        }
        .padding()
    }
}

// MARK: - Extended Scanners Settings

struct ExtendedScannersSettingsView: View {
    @StateObject private var config = ScannerConfiguration.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .font(.title)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading) {
                        Text("Extended Scanners")
                            .font(.headline)
                        Text("Additional persistence vectors to monitor")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 5)

                // Global Toggle
                GroupBox {
                    Toggle(isOn: $config.extendedScannersEnabled) {
                        VStack(alignment: .leading) {
                            Text("Enable Extended Scanners")
                                .fontWeight(.medium)
                            Text("Check additional persistence mechanisms beyond the core set")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                if config.extendedScannersEnabled {
                    // Scanner Categories
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(PersistenceCategory.extendedCategories, id: \.self) { category in
                                ExtendedScannerToggleRow(category: category, config: config)
                                if category != PersistenceCategory.extendedCategories.last {
                                    Divider()
                                }
                            }
                        }
                    }

                    // Quick Actions
                    HStack {
                        Button("Enable All") {
                            config.enableAllExtended()
                        }
                        .buttonStyle(.bordered)

                        Button("Disable All") {
                            config.disableAllExtended()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Reset to Defaults") {
                            config.resetToDefaults()
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                }

                // Info Box
                GroupBox {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("About Extended Scanners")
                                .fontWeight(.medium)
                            Text("Extended scanners check less common but real persistence vectors. Some may require Full Disk Access permission. Enable only what you need for faster scans.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
    }
}

struct ExtendedScannerToggleRow: View {
    let category: PersistenceCategory
    @ObservedObject var config: ScannerConfiguration

    var body: some View {
        Toggle(isOn: Binding(
            get: { config.enabledCategories.contains(category) },
            set: { config.setEnabled(category, enabled: $0) }
        )) {
            HStack {
                Image(systemName: category.systemImage)
                    .frame(width: 20)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(category.displayName)
                            .fontWeight(.medium)

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

                    Text(category.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("MacPersistenceChecker")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .foregroundColor(.secondary)

            Text("A comprehensive tool for monitoring macOS persistence mechanisms.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            // Scanner Stats
            GroupBox {
                HStack(spacing: 20) {
                    VStack {
                        Text("\(PersistenceCategory.coreCategories.count)")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Core")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()
                        .frame(height: 30)

                    VStack {
                        Text("\(PersistenceCategory.extendedCategories.count)")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Extended")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()
                        .frame(height: 30)

                    VStack {
                        Text("\(PersistenceCategory.allCases.count)")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Total")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }

            Spacer()

            // Developer info
            VStack(spacing: 4) {
                Text("Developed by pinperepette")
                    .font(.caption)
                    .fontWeight(.medium)
                Text("2025")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 8)
        }
        .padding()
    }
}
