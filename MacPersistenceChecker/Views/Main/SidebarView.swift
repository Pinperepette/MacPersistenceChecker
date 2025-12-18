import SwiftUI
import Charts

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var scannerConfig = ScannerConfiguration.shared

    /// Enabled extended categories based on configuration
    private var enabledExtendedCategories: [PersistenceCategory] {
        PersistenceCategory.extendedCategories.filter { scannerConfig.enabledCategories.contains($0) }
    }

    var body: some View {
        List(selection: $appState.selectedCategory) {
            // Extended Scanners Toggle - prominente in alto
            Section {
                Toggle(isOn: $scannerConfig.extendedScannersEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Extended Scanners")
                            if scannerConfig.extendedScannersEnabled {
                                Text("\(enabledExtendedCategories.count)/\(PersistenceCategory.extendedCategories.count) active")
                                    .font(.caption2)
                                    .foregroundColor(.purple)
                            }
                        }
                    } icon: {
                        Image(systemName: scannerConfig.extendedScannersEnabled ? "plus.circle.fill" : "plus.circle")
                            .foregroundColor(.purple)
                    }
                }
                .toggleStyle(.switch)
                .tint(.purple)
            }

            // Overview section
            Section("Overview") {
                NavigationLink(value: Optional<PersistenceCategory>.none) {
                    Label {
                        HStack {
                            Text("All Items")
                            Spacer()
                            Text("\(appState.totalCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    } icon: {
                        Image(systemName: "list.bullet")
                    }
                }
                .tag(Optional<PersistenceCategory>.none)

                // Suspicious items quick filter
                if appState.suspiciousCount > 0 {
                    Button {
                        appState.selectedCategory = nil
                        appState.trustFilter = .unsigned
                    } label: {
                        Label {
                            HStack {
                                Text("Suspicious")
                                Spacer()
                                Text("\(appState.suspiciousCount)")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red)
                                    .clipShape(Capsule())
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Core Categories section
            Section("Core Scanners") {
                ForEach(PersistenceCategory.coreCategories, id: \.self) { category in
                    NavigationLink(value: category as PersistenceCategory?) {
                        CategoryRow(
                            category: category,
                            count: appState.itemCount(for: category)
                        )
                    }
                    .tag(category as PersistenceCategory?)
                }
            }

            // Extended Categories section (only if enabled)
            if scannerConfig.extendedScannersEnabled {
                Section("Extended Scanners") {
                    ForEach(enabledExtendedCategories, id: \.self) { category in
                        NavigationLink(value: category as PersistenceCategory?) {
                            CategoryRow(
                                category: category,
                                count: appState.itemCount(for: category),
                                isExtended: true
                            )
                        }
                        .tag(category as PersistenceCategory?)
                    }

                    if enabledExtendedCategories.isEmpty {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("No extended scanners enabled")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // Visual statistics section with charts
            Section("Statistics") {
                if !appState.items.isEmpty {
                    // Trust Level Donut Chart
                    TrustLevelChartView(
                        items: appState.items,
                        showLegend: true,
                        compact: true
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                    // Risk Distribution Bar Chart
                    RiskDistributionChartView(
                        items: appState.items,
                        compact: true
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } else {
                    // Fallback text stats when no items
                    StatsRow(
                        title: "No items scanned",
                        count: 0,
                        color: .secondary
                    )
                }
            }

            // Scan section - prominent
            Section {
                VStack(spacing: 12) {
                    // Progress or date display
                    if appState.isScanning {
                        VStack(spacing: 8) {
                            ProgressView(value: appState.scanProgress)
                                .progressViewStyle(.linear)

                            if let category = appState.currentScanCategory {
                                Text("Scanning \(category.displayName)...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Preparing scan...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } else if let scanDate = appState.lastScanDate {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Last scan")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(scanDate, format: .dateTime.day().month().hour().minute())
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            Spacer()
                        }
                    } else {
                        HStack {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundColor(.orange)
                            Text("No scan yet")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }

                    // Scan button
                    Button {
                        Task {
                            await appState.scanAll()
                        }
                    } label: {
                        HStack {
                            Image(systemName: appState.isScanning ? "stop.fill" : "arrow.clockwise")
                            Text(appState.isScanning ? "Scanning..." : "Scan Now")
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appState.isScanning ? .gray : .accentColor)
                    .disabled(appState.isScanning)
                }
                .padding(.vertical, 4)
            } header: {
                Label("Scan", systemImage: "magnifyingglass")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Persistence")
    }
}

// MARK: - Category Row

struct CategoryRow: View {
    let category: PersistenceCategory
    let count: Int
    var isExtended: Bool = false

    var body: some View {
        Label {
            HStack {
                Text(category.displayName)

                if isExtended && category.requiresFullDiskAccess {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                Spacer()

                if count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        } icon: {
            Image(systemName: category.systemImage)
                .foregroundColor(isExtended ? .purple : .accentColor)
        }
    }
}

// MARK: - Stats Row

struct StatsRow: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Text("\(count)")
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    SidebarView()
        .environmentObject(AppState.shared)
        .frame(width: 250)
}
