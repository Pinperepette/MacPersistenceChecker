import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } content: {
            CategoryListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 600)
                .searchable(text: $appState.searchQuery, placement: .toolbar, prompt: "Search items...")
        } detail: {
            ItemDetailView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        }
        .toolbar {
            // Extended Scanners toggle - BEN VISIBILE
            ToolbarItem(placement: .primaryAction) {
                ExtendedScannersToolbarButton()
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await appState.scanAll()
                    }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isScanning)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await appState.createManualSnapshot()
                    }
                } label: {
                    Label("Snapshot", systemImage: "camera")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showSnapshotsSheet = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "graph-window")
                } label: {
                    Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(appState.items.isEmpty)
            }
        }
        .sheet(isPresented: $appState.showSnapshotsSheet) {
            SnapshotListView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Graph Sheet View

struct GraphSheetView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Persistence Graph")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Graph
            GraphView()
                .environmentObject(appState)
        }
        .frame(minWidth: 900, minHeight: 600)
        .frame(idealWidth: 1100, idealHeight: 700)
    }
}


// MARK: - Extended Scanners Toolbar Button

struct ExtendedScannersToolbarButton: View {
    @ObservedObject private var config = ScannerConfiguration.shared

    var enabledCount: Int {
        PersistenceCategory.extendedCategories.filter { config.enabledCategories.contains($0) }.count
    }

    var body: some View {
        Button {
            config.extendedScannersEnabled.toggle()
            if config.extendedScannersEnabled {
                // Enable all extended scanners when turning on
                config.enableAllExtended()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: config.extendedScannersEnabled ? "plus.circle.fill" : "plus.circle")
                    .foregroundColor(config.extendedScannersEnabled ? .purple : .secondary)
                if config.extendedScannersEnabled {
                    Text("Extended ON")
                        .font(.caption)
                        .foregroundColor(.purple)
                }
            }
        }
        .help(config.extendedScannersEnabled ? "Extended scanners: \(enabledCount) active - Click to disable" : "Click to enable extended scanners")
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
}
