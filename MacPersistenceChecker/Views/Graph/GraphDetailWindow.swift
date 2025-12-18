import SwiftUI

// MARK: - Reusable Components (must be defined first)

struct DetailSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    content
                }
            }
        }
    }
}

struct GraphDetailRow: View {
    let label: String
    let value: String
    var monospace: Bool = false
    var copyable: Bool = false
    var color: Color? = nil

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)

            if monospace {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(color)
                    .textSelection(.enabled)
                    .lineLimit(3)
            } else {
                Text(value)
                    .foregroundColor(color)
                    .textSelection(.enabled)
            }

            Spacer()

            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
    }
}

// MARK: - Graph Detail Window View

struct GraphDetailWindowView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        Group {
            if let edge = appState.graphDetailEdge {
                EdgeDetailView(
                    edge: edge,
                    sourceNode: appState.graphDetailSourceNode,
                    targetNode: appState.graphDetailTargetNode,
                    persistenceItem: appState.graphDetailPersistenceItem
                )
            } else if let node = appState.graphDetailNode {
                NodeFullDetailView(
                    node: node,
                    persistenceItem: appState.graphDetailPersistenceItem
                )
            } else {
                EmptyDetailView()
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

// MARK: - Empty State

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("No Selection")
                .font(.title2)
                .fontWeight(.medium)

            Text("Click on a node or relationship in the graph\nto see detailed information here.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Edge Detail View

struct EdgeDetailView: View {
    let edge: GraphEdge
    let sourceNode: GraphNode?
    let targetNode: GraphNode?
    let persistenceItem: PersistenceItem?

    var body: some View {
        HSplitView {
            // Left: Mini Graph
            MiniGraphView(
                sourceNode: sourceNode,
                targetNode: targetNode,
                edge: edge
            )
            .frame(minWidth: 300)

            // Right: Full Details
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    RelationshipHeaderView(edge: edge, sourceNode: sourceNode, targetNode: targetNode)

                    Divider()

                    // Relationship Details
                    RelationshipDetailsSection(edge: edge)

                    // Source Node Details
                    if let source = sourceNode {
                        NodeDetailsSection(title: "Source", node: source, persistenceItem: persistenceItem)
                    }

                    // Target Node Details
                    if let target = targetNode {
                        NodeDetailsSection(title: "Target", node: target, persistenceItem: nil)
                    }

                    // Full Persistence Item Details (if available)
                    if let item = persistenceItem {
                        PersistenceItemFullDetailsSection(item: item)
                    }
                }
                .padding()
            }
            .frame(minWidth: 350)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Node Full Detail View

struct NodeFullDetailView: View {
    let node: GraphNode
    let persistenceItem: PersistenceItem?

    var body: some View {
        HSplitView {
            // Left: Mini Graph (single node with connections)
            SingleNodeGraphView(node: node)
                .frame(minWidth: 300)

            // Right: Full Details
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    NodeHeaderView(node: node)

                    Divider()

                    // Node Basic Info
                    NodeBasicInfoSection(node: node)

                    // Full Persistence Item Details (if available)
                    if let item = persistenceItem {
                        PersistenceItemFullDetailsSection(item: item)
                    }
                }
                .padding()
            }
            .frame(minWidth: 350)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Mini Graph View (for Edge)

struct MiniGraphView: View {
    let sourceNode: GraphNode?
    let targetNode: GraphNode?
    let edge: GraphEdge

    var body: some View {
        GeometryReader { geometry in
            let centerY = geometry.size.height / 2
            let leftX = geometry.size.width * 0.25
            let rightX = geometry.size.width * 0.75

            ZStack {
                Color(nsColor: .controlBackgroundColor)

                // Draw edge line
                Path { path in
                    path.move(to: CGPoint(x: leftX + 50, y: centerY))
                    path.addLine(to: CGPoint(x: rightX - 50, y: centerY))
                }
                .stroke(edge.relationship.color, style: edge.relationship.lineStyle)

                // Arrow
                Path { path in
                    let arrowX = rightX - 60
                    path.move(to: CGPoint(x: arrowX, y: centerY))
                    path.addLine(to: CGPoint(x: arrowX - 15, y: centerY - 10))
                    path.move(to: CGPoint(x: arrowX, y: centerY))
                    path.addLine(to: CGPoint(x: arrowX - 15, y: centerY + 10))
                }
                .stroke(edge.relationship.color, lineWidth: 2)

                // Relationship label
                Text(edge.relationship.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(edge.relationship.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
                    .position(x: geometry.size.width / 2, y: centerY - 25)

                // Source Node
                if let source = sourceNode {
                    MiniNodeView(node: source)
                        .position(x: leftX, y: centerY)
                }

                // Target Node
                if let target = targetNode {
                    MiniNodeView(node: target)
                        .position(x: rightX, y: centerY)
                }
            }
        }
    }
}

// MARK: - Single Node Graph View

struct SingleNodeGraphView: View {
    let node: GraphNode

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .controlBackgroundColor)

                // Central node (larger)
                LargeNodeView(node: node)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
    }
}

// MARK: - Mini Node View

struct MiniNodeView: View {
    let node: GraphNode

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(node.type.color.opacity(0.2))
                    .frame(width: 60, height: 60)

                Circle()
                    .stroke(node.type.color, lineWidth: 3)
                    .frame(width: 60, height: 60)

                Image(systemName: node.type.icon)
                    .font(.system(size: 24))
                    .foregroundColor(node.type.color)
            }

            Text(node.label)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 100)

            Text(node.type.rawValue)
                .font(.caption2)
                .foregroundColor(.secondary)

            if let risk = node.riskScore, risk > 0 {
                RiskBadge(score: risk)
            }
        }
    }
}

// MARK: - Large Node View

struct LargeNodeView: View {
    let node: GraphNode

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(node.type.color.opacity(0.2))
                    .frame(width: 100, height: 100)

                Circle()
                    .stroke(node.type.color, lineWidth: 4)
                    .frame(width: 100, height: 100)

                Image(systemName: node.type.icon)
                    .font(.system(size: 40))
                    .foregroundColor(node.type.color)
            }

            Text(node.label)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)

            Text(node.type.rawValue)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let risk = node.riskScore, risk > 0 {
                RiskBadge(score: risk, size: .large)
            }
        }
    }
}

// MARK: - Risk Badge

struct RiskBadge: View {
    let score: Int
    var size: Size = .small

    enum Size {
        case small, large
    }

    private var color: Color {
        switch score {
        case 0..<25: return .green
        case 25..<50: return .yellow
        case 50..<75: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(size == .small ? .caption2 : .caption)
            Text("Risk: \(score)")
                .font(size == .small ? .caption2 : .caption)
                .fontWeight(.bold)
        }
        .foregroundColor(.white)
        .padding(.horizontal, size == .small ? 6 : 10)
        .padding(.vertical, size == .small ? 2 : 4)
        .background(color)
        .cornerRadius(size == .small ? 4 : 6)
    }
}

// MARK: - Header Views

struct RelationshipHeaderView: View {
    let edge: GraphEdge
    let sourceNode: GraphNode?
    let targetNode: GraphNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title)
                    .foregroundColor(edge.relationship.color)

                VStack(alignment: .leading) {
                    Text("Relationship Details")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("\(sourceNode?.label ?? "Unknown") \(edge.relationship.rawValue) \(targetNode?.label ?? "Unknown")")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct NodeHeaderView: View {
    let node: GraphNode

    var body: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(node.type.color.opacity(0.2))
                    .frame(width: 50, height: 50)

                Image(systemName: node.type.icon)
                    .font(.title2)
                    .foregroundColor(node.type.color)
            }

            VStack(alignment: .leading) {
                Text(node.label)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(node.type.rawValue)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let risk = node.riskScore, risk > 0 {
                RiskBadge(score: risk, size: .large)
            }
        }
    }
}

// MARK: - Detail Sections

struct RelationshipDetailsSection: View {
    let edge: GraphEdge

    var body: some View {
        DetailSection(title: "Relationship Info", icon: "link") {
            GraphDetailRow(label: "Type", value: edge.relationship.rawValue)
            GraphDetailRow(label: "Edge ID", value: edge.id, monospace: true)
            GraphDetailRow(label: "Source ID", value: edge.sourceId, monospace: true)
            GraphDetailRow(label: "Target ID", value: edge.targetId, monospace: true)
            if let details = edge.details {
                GraphDetailRow(label: "Details", value: details)
            }
        }
    }
}

struct NodeDetailsSection: View {
    let title: String
    let node: GraphNode
    let persistenceItem: PersistenceItem?

    var body: some View {
        DetailSection(title: "\(title) Node", icon: node.type.icon) {
            GraphDetailRow(label: "Label", value: node.label)
            GraphDetailRow(label: "Type", value: node.type.rawValue)
            GraphDetailRow(label: "Node ID", value: node.id, monospace: true)
            if let path = node.path {
                GraphDetailRow(label: "Path", value: path, monospace: true, copyable: true)
            }
            if let details = node.details {
                GraphDetailRow(label: "Details", value: details)
            }
            if let risk = node.riskScore {
                GraphDetailRow(label: "Risk Score", value: "\(risk)/100")
            }
        }
    }
}

struct NodeBasicInfoSection: View {
    let node: GraphNode

    var body: some View {
        DetailSection(title: "Node Information", icon: "info.circle") {
            GraphDetailRow(label: "Label", value: node.label)
            GraphDetailRow(label: "Type", value: node.type.rawValue)
            GraphDetailRow(label: "ID", value: node.id, monospace: true)
            if let path = node.path {
                GraphDetailRow(label: "Path", value: path, monospace: true, copyable: true)
            }
            if let details = node.details {
                GraphDetailRow(label: "Details", value: details)
            }
        }
    }
}

// MARK: - Persistence Item Full Details

struct PersistenceItemFullDetailsSection: View {
    let item: PersistenceItem

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Basic Info
            DetailSection(title: "Persistence Item", icon: "doc.text.fill") {
                GraphDetailRow(label: "Name", value: item.name)
                GraphDetailRow(label: "Identifier", value: item.identifier, monospace: true)
                GraphDetailRow(label: "Category", value: item.category.displayName)
                GraphDetailRow(label: "Trust Level", value: item.trustLevel.displayName, color: item.trustLevel.color)
                GraphDetailRow(label: "Enabled", value: item.isEnabled ? "Yes" : "No", color: item.isEnabled ? .green : .secondary)
                GraphDetailRow(label: "Loaded", value: item.isLoaded ? "Yes" : "No", color: item.isLoaded ? .green : .secondary)
                if let version = item.version {
                    GraphDetailRow(label: "Version", value: version)
                }
                if let bundleId = item.bundleIdentifier {
                    GraphDetailRow(label: "Bundle ID", value: bundleId, monospace: true)
                }
            }

            // Paths
            DetailSection(title: "File Paths", icon: "folder") {
                if let plist = item.plistPath {
                    GraphDetailRow(label: "Plist Path", value: plist.path, monospace: true, copyable: true)
                }
                if let exec = item.executablePath {
                    GraphDetailRow(label: "Executable", value: exec.path, monospace: true, copyable: true)
                }
                if let effective = item.effectiveExecutablePath, effective != item.executablePath {
                    GraphDetailRow(label: "Effective Exec", value: effective.path, monospace: true, copyable: true)
                }
                if let parent = item.parentAppPath {
                    GraphDetailRow(label: "Parent App", value: parent.path, monospace: true, copyable: true)
                }
                if let installer = item.installerPath {
                    GraphDetailRow(label: "Installer", value: installer.path, monospace: true, copyable: true)
                }
                if let workDir = item.workingDirectory {
                    GraphDetailRow(label: "Working Dir", value: workDir, monospace: true)
                }
                if let stdout = item.standardOutPath {
                    GraphDetailRow(label: "Stdout", value: stdout, monospace: true)
                }
                if let stderr = item.standardErrorPath {
                    GraphDetailRow(label: "Stderr", value: stderr, monospace: true)
                }
            }

            // Signature Info
            if let sig = item.signatureInfo {
                DetailSection(title: "Code Signature", icon: "checkmark.seal") {
                    GraphDetailRow(label: "Status", value: sig.isSigned ? "Signed" : "Not Signed", color: sig.isSigned ? .green : .red)
                    if let org = sig.organizationName {
                        GraphDetailRow(label: "Organization", value: org)
                    }
                    if let team = sig.teamIdentifier {
                        GraphDetailRow(label: "Team ID", value: team, monospace: true)
                    }
                    GraphDetailRow(label: "Apple Signed", value: sig.isAppleSigned ? "Yes" : "No", color: sig.isAppleSigned ? .green : .secondary)
                    GraphDetailRow(label: "Notarized", value: sig.isNotarized ? "Yes" : "No", color: sig.isNotarized ? .green : .secondary)
                    GraphDetailRow(label: "Valid", value: sig.isValid ? "Yes" : "No", color: sig.isValid ? .green : .red)
                    if sig.isCertificateExpired {
                        GraphDetailRow(label: "Certificate", value: "Expired", color: .red)
                    }
                    if let authority = sig.signingAuthority {
                        GraphDetailRow(label: "Authority", value: authority)
                    }
                }
            }

            // Plist Configuration
            if item.programArguments != nil || item.runAtLoad != nil || item.keepAlive != nil || item.environmentVariables != nil {
                DetailSection(title: "Plist Configuration", icon: "gearshape") {
                    if let runAtLoad = item.runAtLoad {
                        GraphDetailRow(label: "Run At Load", value: runAtLoad ? "Yes" : "No", color: runAtLoad ? .orange : .secondary)
                    }
                    if let keepAlive = item.keepAlive {
                        GraphDetailRow(label: "Keep Alive", value: keepAlive ? "Yes" : "No", color: keepAlive ? .orange : .secondary)
                    }
                    if let args = item.programArguments, !args.isEmpty {
                        GraphDetailRow(label: "Program Args", value: args.joined(separator: " "), monospace: true)
                    }
                    if let env = item.environmentVariables, !env.isEmpty {
                        ForEach(Array(env.keys.sorted()), id: \.self) { key in
                            GraphDetailRow(label: key, value: env[key] ?? "", monospace: true)
                        }
                    }
                }
            }

            // Timestamps
            DetailSection(title: "Timestamps (Forensics)", icon: "clock") {
                if let created = item.plistCreatedAt {
                    GraphDetailRow(label: "Plist Created", value: dateFormatter.string(from: created))
                }
                if let modified = item.plistModifiedAt {
                    GraphDetailRow(label: "Plist Modified", value: dateFormatter.string(from: modified))
                }
                if let binCreated = item.binaryCreatedAt {
                    GraphDetailRow(label: "Binary Created", value: dateFormatter.string(from: binCreated))
                }
                if let binModified = item.binaryModifiedAt {
                    GraphDetailRow(label: "Binary Modified", value: dateFormatter.string(from: binModified))
                }
                if let binExec = item.binaryLastExecutedAt {
                    GraphDetailRow(label: "Last Executed", value: dateFormatter.string(from: binExec))
                }
                GraphDetailRow(label: "Discovered", value: dateFormatter.string(from: item.discoveredAt))
                if let netFirst = item.networkFirstSeenAt {
                    GraphDetailRow(label: "Network First", value: dateFormatter.string(from: netFirst))
                }
                if let netLast = item.networkLastSeenAt {
                    GraphDetailRow(label: "Network Last", value: dateFormatter.string(from: netLast))
                }
            }

            // Risk Assessment
            if let riskScore = item.riskScore {
                DetailSection(title: "Risk Assessment", icon: "exclamationmark.triangle") {
                    HStack {
                        Text("Risk Score")
                            .foregroundColor(.secondary)
                        Spacer()
                        RiskScoreBar(score: riskScore)
                    }

                    if let details = item.riskDetails, !details.isEmpty {
                        Divider()
                        ForEach(details, id: \.factor) { detail in
                            HStack(alignment: .top) {
                                Circle()
                                    .fill(riskDetailColor(for: detail.points))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 5)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(detail.factor)
                                        .fontWeight(.medium)
                                    Text(detail.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Text("+\(detail.points)")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(riskDetailColor(for: detail.points))
                            }
                        }
                    }
                }
            }

            // Signed-but-Dangerous Flags
            if let flags = item.signedButDangerousFlags, !flags.isEmpty {
                DetailSection(title: "Signed-but-Dangerous Analysis", icon: "exclamationmark.shield") {
                    if let risk = item.signedButDangerousRisk {
                        GraphDetailRow(label: "Risk Level", value: risk, color: signedDangerousColor(for: risk))
                    }

                    Divider()

                    ForEach(flags) { flag in
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(flagSeverityColor(flag.severity))
                                .font(.caption)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(flag.title)
                                    .fontWeight(.medium)
                                Text(flag.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text("+\(flag.points)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(flagSeverityColor(flag.severity))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func riskDetailColor(for points: Int) -> Color {
        switch points {
        case 0..<10: return .yellow
        case 10..<20: return .orange
        default: return .red
        }
    }

    private func signedDangerousColor(for risk: String) -> Color {
        switch risk.lowercased() {
        case "low": return .green
        case "medium": return .yellow
        case "high": return .orange
        case "critical": return .red
        default: return .secondary
        }
    }

    private func flagSeverityColor(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "low": return .yellow
        case "medium": return .orange
        case "high", "critical": return .red
        default: return .secondary
        }
    }
}

// MARK: - Risk Score Bar

struct RiskScoreBar: View {
    let score: Int

    private var color: Color {
        switch score {
        case 0..<25: return .green
        case 25..<50: return .yellow
        case 50..<75: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(score) / 100)
                }
            }
            .frame(width: 100, height: 8)

            Text("\(score)")
                .font(.system(.body, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(color)
        }
    }
}

// MARK: - Preview

#Preview {
    GraphDetailWindowView()
        .environmentObject(AppState.shared)
        .frame(width: 900, height: 700)
}
