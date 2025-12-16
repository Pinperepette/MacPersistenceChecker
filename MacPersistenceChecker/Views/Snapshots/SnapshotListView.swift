import SwiftUI

struct SnapshotListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSnapshots: Set<UUID> = []
    @State private var showingDiff = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Toolbar
                snapshotToolbar

                Divider()

                // Content
                if appState.snapshots.isEmpty {
                    emptyState
                } else {
                    snapshotList
                }
            }
            .frame(width: 600, height: 500)
            .navigationTitle("Snapshot History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingDiff) {
            if selectedSnapshots.count == 2 {
                let snapshots = appState.snapshots.filter { selectedSnapshots.contains($0.id) }
                if snapshots.count == 2 {
                    DiffView(
                        fromSnapshot: snapshots[1], // Older
                        toSnapshot: snapshots[0]    // Newer
                    )
                    .environmentObject(appState)
                }
            }
        }
    }

    // MARK: - Toolbar

    private var snapshotToolbar: some View {
        HStack {
            Button {
                Task {
                    await appState.createManualSnapshot()
                }
            } label: {
                Label("New Snapshot", systemImage: "camera")
            }
            .disabled(appState.items.isEmpty)

            Spacer()

            if selectedSnapshots.count == 2 {
                Button {
                    showingDiff = true
                } label: {
                    Label("Compare", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Select 2 snapshots to compare")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Snapshots")
                .font(.title2)
                .fontWeight(.medium)

            Text("Create a snapshot to track changes over time")
                .foregroundColor(.secondary)

            Button {
                Task {
                    await appState.createManualSnapshot()
                }
            } label: {
                Label("Create Snapshot", systemImage: "camera")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.items.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Snapshot List

    private var snapshotList: some View {
        List(selection: $selectedSnapshots) {
            ForEach(appState.snapshots) { snapshot in
                SnapshotRow(snapshot: snapshot)
                    .tag(snapshot.id)
                    .contextMenu {
                        Button(role: .destructive) {
                            deleteSnapshot(snapshot)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            .onDelete { indexSet in
                deleteSnapshots(at: indexSet)
            }
        }
        .listStyle(.inset)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    deleteAllSnapshots()
                } label: {
                    Label("Delete All", systemImage: "trash.fill")
                }
                .disabled(appState.snapshots.isEmpty)
            }
        }
    }

    private func deleteSnapshot(_ snapshot: Snapshot) {
        do {
            try DatabaseManager.shared.deleteSnapshot(snapshot.id)
            appState.loadSnapshots()
        } catch {
            print("Failed to delete snapshot: \(error)")
        }
    }

    private func deleteSnapshots(at offsets: IndexSet) {
        for index in offsets {
            let snapshot = appState.snapshots[index]
            do {
                try DatabaseManager.shared.deleteSnapshot(snapshot.id)
            } catch {
                print("Failed to delete snapshot: \(error)")
            }
        }
        appState.loadSnapshots()
    }

    private func deleteAllSnapshots() {
        for snapshot in appState.snapshots {
            do {
                try DatabaseManager.shared.deleteSnapshot(snapshot.id)
            } catch {
                print("Failed to delete snapshot: \(error)")
            }
        }
        appState.loadSnapshots()
    }
}

// MARK: - Snapshot Row

struct SnapshotRow: View {
    let snapshot: Snapshot

    var body: some View {
        HStack(spacing: 12) {
            // Trigger icon
            Image(systemName: snapshot.trigger.symbolName)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                // Date
                Text(snapshot.displayDate)
                    .font(.headline)

                // Trigger and count
                HStack {
                    Text(snapshot.trigger.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())

                    Text("\(snapshot.itemCount) items")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Note
                if let note = snapshot.note {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Relative time
            Text(snapshot.relativeDate)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Diff View

struct DiffView: View {
    let fromSnapshot: Snapshot
    let toSnapshot: Snapshot
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var diff: SnapshotDiff?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Computing diff...")
                } else if let diff = diff {
                    diffContent(diff)
                } else {
                    Text("Failed to compute diff")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Comparison")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 700, height: 500)
        .task {
            await computeDiff()
        }
    }

    private func diffContent(_ diff: SnapshotDiff) -> some View {
        VStack(spacing: 0) {
            // Header
            diffHeader(diff)

            Divider()

            // Content
            if diff.hasChanges {
                diffList(diff)
            } else {
                noChangesView
            }
        }
    }

    private func diffHeader(_ diff: SnapshotDiff) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text("From: \(fromSnapshot.displayDate)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("To: \(toSnapshot.displayDate)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(diff.summary)
                .font(.headline)
        }
        .padding()
    }

    private func diffList(_ diff: SnapshotDiff) -> some View {
        List {
            ForEach(diff.groupedChanges, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        DiffItemRow(item: item)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var noChangesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("No Changes")
                .font(.title2)
                .fontWeight(.medium)

            Text("The system state is identical between these snapshots")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func computeDiff() async {
        isLoading = true

        do {
            let fromItems = try DatabaseManager.shared.getItems(for: fromSnapshot.id)
            let toItems = try DatabaseManager.shared.getItems(for: toSnapshot.id)

            let engine = DiffEngine()
            diff = engine.compute(from: fromItems, to: toItems, fromSnapshot: fromSnapshot, toSnapshot: toSnapshot)
        } catch {
            print("Failed to compute diff: \(error)")
        }

        isLoading = false
    }
}

// MARK: - Diff Item Row

struct DiffItemRow: View {
    let item: DiffDisplayItem

    var body: some View {
        HStack(spacing: 12) {
            // Change type icon
            Image(systemName: item.changeType.symbolName)
                .foregroundColor(changeColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.item.name)
                    .font(.headline)

                Text(item.item.identifier)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Change details
                if !item.changes.isEmpty {
                    ForEach(item.changes, id: \.field) { change in
                        Text(change.shortDescription)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Trust badge
            TrustBadgeView(trustLevel: item.item.trustLevel)
        }
        .padding(.vertical, 4)
    }

    private var changeColor: Color {
        switch item.changeType {
        case .added: return .green
        case .removed: return .red
        case .modified, .enabled, .disabled, .trustLevelChanged: return .orange
        }
    }
}

// MARK: - Diff Engine

final class DiffEngine {
    func compute(
        from fromItems: [PersistenceItem],
        to toItems: [PersistenceItem],
        fromSnapshot: Snapshot,
        toSnapshot: Snapshot
    ) -> SnapshotDiff {
        let fromSet = Set(fromItems.map { $0.identifier })
        let toSet = Set(toItems.map { $0.identifier })

        // Added items (in 'to' but not in 'from')
        let addedIdentifiers = toSet.subtracting(fromSet)
        let addedItems = toItems.filter { addedIdentifiers.contains($0.identifier) }

        // Removed items (in 'from' but not in 'to')
        let removedIdentifiers = fromSet.subtracting(toSet)
        let removedItems = fromItems.filter { removedIdentifiers.contains($0.identifier) }

        // Changed items (in both, but different)
        var changedItems: [ItemChange] = []
        let commonIdentifiers = fromSet.intersection(toSet)

        for identifier in commonIdentifiers {
            guard let fromItem = fromItems.first(where: { $0.identifier == identifier }),
                  let toItem = toItems.first(where: { $0.identifier == identifier }) else {
                continue
            }

            let changes = findChanges(from: fromItem, to: toItem)
            if !changes.isEmpty {
                changedItems.append(ItemChange(
                    item: toItem,
                    changeType: .modified,
                    details: changes
                ))
            }
        }

        return SnapshotDiff(
            fromSnapshot: fromSnapshot,
            toSnapshot: toSnapshot,
            addedItems: addedItems,
            removedItems: removedItems,
            changedItems: changedItems
        )
    }

    private func findChanges(from: PersistenceItem, to: PersistenceItem) -> [ChangeDetail] {
        var changes: [ChangeDetail] = []

        if from.isEnabled != to.isEnabled {
            changes.append(ChangeDetail(
                field: "Enabled",
                oldValue: from.isEnabled ? "Yes" : "No",
                newValue: to.isEnabled ? "Yes" : "No"
            ))
        }

        if from.trustLevel != to.trustLevel {
            changes.append(ChangeDetail(
                field: "Trust Level",
                oldValue: from.trustLevel.displayName,
                newValue: to.trustLevel.displayName
            ))
        }

        if from.executablePath?.path != to.executablePath?.path {
            changes.append(ChangeDetail(
                field: "Executable",
                oldValue: from.executablePath?.path ?? "None",
                newValue: to.executablePath?.path ?? "None"
            ))
        }

        return changes
    }
}

#Preview {
    SnapshotListView()
        .environmentObject(AppState.shared)
}
