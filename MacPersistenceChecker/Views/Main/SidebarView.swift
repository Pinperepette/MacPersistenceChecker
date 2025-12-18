import SwiftUI

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

            // Quick stats section
            Section("Statistics") {
                StatsRow(
                    title: "Apple Signed",
                    count: appState.items.filter { $0.trustLevel == .apple }.count,
                    color: .green
                )

                StatsRow(
                    title: "Known Vendors",
                    count: appState.items.filter { $0.trustLevel == .knownVendor }.count,
                    color: .blue
                )

                StatsRow(
                    title: "Unknown",
                    count: appState.items.filter { $0.trustLevel == .unknown }.count,
                    color: .gray
                )

                StatsRow(
                    title: "Suspicious",
                    count: appState.items.filter { $0.trustLevel == .suspicious }.count,
                    color: .yellow
                )

                StatsRow(
                    title: "Unsigned",
                    count: appState.items.filter { $0.trustLevel == .unsigned }.count,
                    color: .red
                )
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
