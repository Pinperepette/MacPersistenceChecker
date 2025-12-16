import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.selectedCategory) {
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

            // Categories section
            Section("Categories") {
                ForEach(PersistenceCategory.allCases) { category in
                    NavigationLink(value: category as PersistenceCategory?) {
                        CategoryRow(
                            category: category,
                            count: appState.itemCount(for: category)
                        )
                    }
                    .tag(category as PersistenceCategory?)
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
        }
        .listStyle(.sidebar)
        .navigationTitle("Persistence")
    }
}

// MARK: - Category Row

struct CategoryRow: View {
    let category: PersistenceCategory
    let count: Int

    var body: some View {
        Label {
            HStack {
                Text(category.displayName)
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
                .foregroundColor(.accentColor)
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
