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

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    // TODO: Implement update check
                }
            }

            CommandMenu("Scan") {
                Button("Scan All") {
                    Task {
                        await appState.scanAll()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                ForEach(PersistenceCategory.allCases) { category in
                    Button("Scan \(category.displayName)") {
                        Task {
                            await appState.scan(category: category)
                        }
                    }
                }
            }

            CommandMenu("Snapshot") {
                Button("Create Snapshot") {
                    Task {
                        await appState.createManualSnapshot()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("View Snapshots") {
                    appState.showSnapshotsSheet = true
                }
            }
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

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 300)
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
            Toggle("Include system items", isOn: $includeSystemItems)
            Toggle("Verify code signatures", isOn: $verifySignatures)
        }
        .padding()
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

            Spacer()
        }
        .padding()
    }
}
