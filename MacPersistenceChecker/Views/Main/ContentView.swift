import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } content: {
            CategoryListView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 600)
        } detail: {
            ItemDetailView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 400)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task {
                        await appState.scanAll()
                    }
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isScanning)

                Button {
                    Task {
                        await appState.createManualSnapshot()
                    }
                } label: {
                    Label("Snapshot", systemImage: "camera")
                }

                Button {
                    appState.showSnapshotsSheet = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .searchable(text: $appState.searchQuery, prompt: "Search items...")
        .sheet(isPresented: $appState.showSnapshotsSheet) {
            SnapshotListView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Toolbar

struct ToolbarView: ToolbarContent {
    @EnvironmentObject var appState: AppState

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Scan button
            Button {
                Task {
                    await appState.scanAll()
                }
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .disabled(appState.isScanning)
            .help("Scan all persistence mechanisms")

            // Snapshot button
            Button {
                NSLog("📸 Snapshot button pressed! Items count: %d", appState.items.count)
                Task {
                    await appState.createManualSnapshot()
                }
            } label: {
                Label("Snapshot", systemImage: "camera")
            }
            .disabled(appState.isScanning)
            .help("Create a snapshot of current state")

            // History button
            Button {
                NSLog("📜 History button pressed! showSnapshotsSheet = true")
                appState.showSnapshotsSheet = true
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .help("View snapshot history")
        }

        ToolbarItemGroup(placement: .secondaryAction) {
            // Sort menu
            Menu {
                ForEach(SortOrder.allCases) { order in
                    Button {
                        appState.sortOrder = order
                    } label: {
                        Label(order.displayName, systemImage: order.symbolName)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }

            // Filter menu
            Menu {
                Button("All") {
                    appState.trustFilter = nil
                }

                Divider()

                ForEach(TrustLevel.allCases, id: \.self) { level in
                    Button {
                        appState.trustFilter = level
                    } label: {
                        Label(level.displayName, systemImage: level.symbolName)
                    }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }

            // Toggle enabled only
            Toggle(isOn: $appState.showOnlyEnabled) {
                Label("Enabled Only", systemImage: "checkmark.circle")
            }
        }

        // Status
        ToolbarItem(placement: .status) {
            if appState.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)

                    if let category = appState.currentScanCategory {
                        Text("Scanning \(category.displayName)...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.suspiciousCount > 0 ? Color.yellow : Color.green)
                        .frame(width: 8, height: 8)

                    Text("\(appState.totalCount) items")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if appState.suspiciousCount > 0 {
                        Text("(\(appState.suspiciousCount) suspicious)")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState.shared)
}
