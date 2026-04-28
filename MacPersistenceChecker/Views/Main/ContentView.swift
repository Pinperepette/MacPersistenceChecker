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

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "invasiveness-window")
                } label: {
                    Label("App Report", systemImage: "chart.bar.fill")
                }
                .disabled(appState.items.isEmpty)
                .help("Analyze apps for invasiveness")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "stats-dashboard-window")
                } label: {
                    Label("Statistics", systemImage: "chart.pie.fill")
                }
                .disabled(appState.items.isEmpty)
                .help("View statistics dashboard with charts")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    openWindow(id: "smart-triage-window")
                } label: {
                    Label("Triage", systemImage: "rectangle.3.group")
                }
                .disabled(appState.items.isEmpty)
                .help("Cluster-based triage: decide once per concept, propagate to all matching items")

                Button {
                    openWindow(id: "health-report-window")
                } label: {
                    Label("Report", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(appState.items.isEmpty)
                .help("Generate an AI-written narrative health report on this Mac's persistence posture")

                Button {
                    openWindow(id: "threat-hunt-window")
                } label: {
                    Label("Hunt", systemImage: "magnifyingglass.circle")
                }
                .disabled(appState.items.isEmpty)
                .help("Ask a natural-language question against your persistence inventory")

                ShowTrustedToggleButton()
            }

            ToolbarItem(placement: .primaryAction) {
                ForensicExportButton()
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    openSettingsWindow()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
        .sheet(isPresented: $appState.showSnapshotsSheet) {
            SnapshotListView()
                .environmentObject(appState)
        }
        .task {
            // Auto-scan on launch if enabled AND no cached data
            if UserDefaults.standard.bool(forKey: "autoScanOnLaunch") && appState.items.isEmpty {
                await appState.scanAll()
            }
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


// MARK: - Forensic Export Button

struct ForensicExportButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var showExportSuccess = false
    @State private var showExportError = false
    @State private var errorMessage = ""
    @State private var exportedURL: URL?

    var body: some View {
        Button {
            exportForensicJSON()
        } label: {
            if isExporting {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                    Text("Exporting...")
                        .font(.caption)
                }
            } else {
                Label("Export JSON", systemImage: "square.and.arrow.up")
            }
        }
        .disabled(appState.items.isEmpty || isExporting)
        .help(appState.items.isEmpty ? "Run a scan first to export data" : "Export forensic JSON for SIEM/SOAR/IR")
        .alert("Export Successful", isPresented: $showExportSuccess) {
            Button("Show in Finder") {
                if let url = exportedURL {
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Forensic JSON report has been saved.\n\(appState.items.count) items exported.")
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func exportForensicJSON() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "forensic_report_\(formattedDate()).json"
        savePanel.title = "Export Forensic JSON"
        savePanel.message = "Choose where to save the forensic report"

        savePanel.begin { result in
            if result == .OK, let url = savePanel.url {
                isExporting = true
                exportProgress = 0

                // Run export on background thread
                Task.detached(priority: .userInitiated) {
                    do {
                        // Get items on main actor
                        let items = await MainActor.run { appState.items }

                        // Generate report (heavy operation)
                        let exporter = ForensicExporter.shared
                        guard let json = exporter.exportToJSON(items: items) else {
                            throw ForensicExporter.ExportError.encodingFailed
                        }

                        // Write to file
                        try json.write(to: url, atomically: true, encoding: .utf8)

                        await MainActor.run {
                            isExporting = false
                            exportedURL = url
                            showExportSuccess = true
                        }
                    } catch {
                        await MainActor.run {
                            isExporting = false
                            errorMessage = error.localizedDescription
                            showExportError = true
                        }
                    }
                }
            }
        }
    }

    private func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Show Trusted Toggle

struct ShowTrustedToggleButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button {
            appState.hideGraphTrusted.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.hideGraphTrusted ? "eye.slash" : "eye")
                    .foregroundColor(appState.hideGraphTrusted ? .secondary : .accentColor)
                if appState.hideGraphTrusted, appState.trustedHiddenCount > 0 {
                    Text("\(appState.trustedHiddenCount) hidden")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .help(appState.hideGraphTrusted
              ? "Trusted items are hidden — click to show them"
              : "Trusted items are visible — click to hide them")
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

#if XCODE_PREVIEWS
#Preview {
    ContentView()
        .environmentObject(AppState.shared)
}
#endif
