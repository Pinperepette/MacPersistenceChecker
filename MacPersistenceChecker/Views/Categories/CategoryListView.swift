import SwiftUI

struct CategoryListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.isScanning && appState.items.isEmpty {
                ScanningView()
            } else if appState.filteredItems.isEmpty {
                EmptyStateView()
            } else {
                ItemListView()
            }
        }
        .navigationTitle(navigationTitle)
        .navigationSubtitle(navigationSubtitle)
    }

    private var navigationTitle: String {
        if let category = appState.selectedCategory {
            return category.displayName
        }
        return "All Items"
    }

    private var navigationSubtitle: String {
        let count = appState.filteredItems.count
        if count == 1 {
            return "1 item"
        }
        return "\(count) items"
    }
}

// MARK: - Item List

struct ItemListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.selectedItem) {
            ForEach(appState.filteredItems) { item in
                ItemRowView(item: item)
                    .tag(item)
            }
        }
        .listStyle(.inset)
    }
}

// MARK: - Item Row

struct ItemRowView: View {
    let item: PersistenceItem
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Trust badge
            TrustBadgeView(trustLevel: item.trustLevel)

            // Main content
            VStack(alignment: .leading, spacing: 4) {
                // Name
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)

                // Identifier / path
                Text(item.identifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // Vendor / signature info
                if let org = item.signatureInfo?.organizationName {
                    HStack(spacing: 4) {
                        Image(systemName: "building.2")
                            .font(.caption2)
                        Text(org)
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Status indicators
            VStack(alignment: .trailing, spacing: 4) {
                // Category badge
                Text(item.category.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(Capsule())

                // Loaded/Enabled status
                HStack(spacing: 4) {
                    if item.isLoaded {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundColor(.green)
                        Text("Loaded")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else if item.isEnabled {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundColor(.blue)
                        Text("Enabled")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Image(systemName: "circle")
                            .font(.system(size: 6))
                            .foregroundColor(.secondary)
                        Text("Disabled")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            ItemContextMenu(item: item)
        }
    }
}

// MARK: - Trust Badge

struct TrustBadgeView: View {
    let trustLevel: TrustLevel

    var body: some View {
        Image(systemName: trustLevel.symbolName)
            .font(.title2)
            .foregroundColor(trustLevel.color)
            .frame(width: 32, height: 32)
            .background(trustLevel.color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Context Menu

struct ItemContextMenu: View {
    let item: PersistenceItem

    var body: some View {
        Group {
            Button {
                revealInFinder()
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            if item.plistPath != nil {
                Button {
                    showPlist()
                } label: {
                    Label("Show Plist", systemImage: "doc.text")
                }
            }

            Divider()

            Button {
                copyIdentifier()
            } label: {
                Label("Copy Identifier", systemImage: "doc.on.doc")
            }

            if let path = item.executablePath?.path {
                Button {
                    copyPath(path)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
            }

            Divider()

            if item.isEnabled {
                Button(role: .destructive) {
                    disableItem()
                } label: {
                    Label("Disable", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    enableItem()
                } label: {
                    Label("Enable", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private func revealInFinder() {
        let path = item.plistPath ?? item.executablePath
        if let url = path {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    private func showPlist() {
        if let plistPath = item.plistPath {
            NSWorkspace.shared.open(plistPath)
        }
    }

    private func copyIdentifier() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.identifier, forType: .string)
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func disableItem() {
        // TODO: Implement disable
    }

    private func enableItem() {
        // TODO: Implement enable
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            if appState.items.isEmpty {
                Text("No Items Found")
                    .font(.title2)
                    .fontWeight(.medium)

                Text("Click 'Scan' to discover persistence mechanisms")
                    .foregroundColor(.secondary)

                Button("Scan Now") {
                    Task {
                        await appState.scanAll()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("No Matching Items")
                    .font(.title2)
                    .fontWeight(.medium)

                Text("Try adjusting your search or filters")
                    .foregroundColor(.secondary)

                Button("Clear Filters") {
                    appState.searchQuery = ""
                    appState.trustFilter = nil
                    appState.showOnlyEnabled = false
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Scanning View

struct ScanningView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning...")
                .font(.title2)
                .fontWeight(.medium)

            if let category = appState.currentScanCategory {
                Text(category.displayName)
                    .foregroundColor(.secondary)
            }

            ProgressView(value: appState.scanProgress)
                .frame(width: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    CategoryListView()
        .environmentObject(AppState.shared)
}
