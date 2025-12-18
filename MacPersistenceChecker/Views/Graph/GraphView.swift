import SwiftUI

// MARK: - Main Graph View

struct GraphView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var graph = PersistenceGraph()
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showStats: Bool = true
    @State private var isFullAnalysis: Bool = false
    @State private var viewSize: CGSize = .zero

    private let analyzer = GraphAnalyzer()

    /// Check if we have a focused item to show
    private var isFocusedMode: Bool {
        appState.focusedGraphItem != nil
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color(nsColor: .controlBackgroundColor)

                if graph.nodes.isEmpty && !graph.isAnalyzing {
                    if isFocusedMode {
                        // Auto-start for focused mode
                        Color.clear.onAppear {
                            viewSize = geometry.size
                            startFocusedAnalysis()
                        }
                        AnalyzingView(progress: 0.5)
                    } else {
                        EmptyGraphView(onAnalyze: startAnalysis)
                    }
                } else if graph.isAnalyzing {
                    AnalyzingView(progress: graph.analysisProgress)
                } else {
                    // Graph canvas
                    GraphCanvas(graph: graph, scale: scale, offset: offset)
                        .gesture(dragGesture)
                        .gesture(magnificationGesture)
                        .onAppear {
                            viewSize = geometry.size
                        }
                        .onChange(of: geometry.size) { newSize in
                            viewSize = newSize
                        }
                }

                // Overlay controls
                VStack {
                    HStack {
                        // Stats panel
                        if showStats && !graph.nodes.isEmpty {
                            GraphStatsPanel(stats: graph.statistics)
                        }

                        Spacer()

                        // Focused item indicator
                        if let focusedItem = appState.focusedGraphItem {
                            HStack(spacing: 8) {
                                Image(systemName: "scope")
                                    .foregroundColor(.purple)
                                Text(focusedItem.name)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Button {
                                    appState.focusedGraphItem = nil
                                    graph.clear()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Show full graph")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                        } else {
                            // Analysis mode picker (only for full graph)
                            Picker("Mode", selection: $isFullAnalysis) {
                                Text("Quick").tag(false)
                                Text("Full").tag(true)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 120)
                            .help("Quick: Basic relationships. Full: Includes dylibs and network")
                        }

                        // Controls
                        GraphControlsPanel(
                            showStats: $showStats,
                            scale: $scale,
                            onReset: resetView,
                            onRefresh: { isFocusedMode ? startFocusedAnalysis() : startAnalysis() },
                            isAnalyzing: graph.isAnalyzing
                        )
                    }
                    .padding()

                    Spacer()

                    // Selected node details
                    if let selectedNode = graph.selectedNode {
                        NodeDetailPanel(node: selectedNode, graph: graph)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    // Selected edge details
                    if let selectedEdge = graph.selectedEdge {
                        EdgeDetailPanel(edge: selectedEdge, graph: graph)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                // Legend (hide when detail panel is open)
                if !graph.nodes.isEmpty && graph.selectedNode == nil && graph.selectedEdge == nil {
                    VStack {
                        Spacer()
                        HStack {
                            GraphLegend()
                                .padding()
                            Spacer()
                        }
                    }
                }
            }
        }
        .onAppear {
            // Auto-start if we have a focused item
            if isFocusedMode && graph.nodes.isEmpty {
                startFocusedAnalysis()
            }
        }
        .onChange(of: appState.focusedGraphItem?.id) { _ in
            // Reset and rebuild when focused item changes
            if isFocusedMode {
                graph.clear()
                resetView()
                startFocusedAnalysis()
            }
        }
    }

    // MARK: - Gestures

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(0.3, min(3.0, value))
            }
    }

    // MARK: - Actions

    private func startAnalysis() {
        let allItems = appState.items
        guard !allItems.isEmpty else {
            print("No items to analyze")
            return
        }

        // Limita a max 50 items (quelli con risk score più alto)
        let items = Array(allItems.sorted { ($0.riskScore ?? 0) > ($1.riskScore ?? 0) }.prefix(50))

        graph.isAnalyzing = true
        graph.analysisProgress = 0.05

        let currentViewSize = viewSize
        let width = max(currentViewSize.width, 900)
        let height = max(currentViewSize.height, 600)
        let doFullAnalysis = isFullAnalysis

        // Esegui in background per non bloccare UI
        Task.detached(priority: .userInitiated) {
            var nodes: [GraphNode] = []
            var edges: [GraphEdge] = []
            var addedBinaries = Set<String>()
            var addedDylibs = Set<String>()

            let centerX = width / 2
            let centerY = height / 2
            let radius = min(width, height) * 0.35

            for (index, item) in items.enumerated() {
                let nodeType: GraphNode.NodeType = {
                    switch item.category {
                    case .launchAgents: return .launchAgent
                    case .launchDaemons: return .launchDaemon
                    case .loginItems: return .loginItem
                    case .kernelExtensions: return .kext
                    case .systemExtensions: return .systemExtension
                    case .cronJobs: return .cronJob
                    case .shellStartupFiles, .periodicScripts: return .script
                    default: return .plist
                    }
                }()

                let angle = (2.0 * Double.pi * Double(index)) / Double(items.count)

                var itemNode = GraphNode(
                    id: "item:\(index)",
                    type: nodeType,
                    label: String(item.name.prefix(18)),
                    details: item.identifier,
                    path: item.plistPath?.path,
                    riskScore: item.riskScore,
                    persistenceItemId: item.id
                )
                itemNode.position = CGPoint(
                    x: centerX + radius * cos(angle),
                    y: centerY + radius * sin(angle)
                )
                nodes.append(itemNode)

                // Binary collegato
                if let execPath = item.effectiveExecutablePath {
                    let binName = execPath.lastPathComponent
                    let execId = "bin:\(binName.hashValue)"

                    if !addedBinaries.contains(execId) {
                        addedBinaries.insert(execId)
                        let innerRadius = radius * 0.5
                        var binaryNode = GraphNode(
                            id: execId,
                            type: .binary,
                            label: String(binName.prefix(15)),
                            details: nil,
                            path: execPath.path,
                            riskScore: nil,
                            persistenceItemId: nil
                        )
                        binaryNode.position = CGPoint(
                            x: centerX + innerRadius * cos(angle + 0.1),
                            y: centerY + innerRadius * sin(angle + 0.1)
                        )
                        nodes.append(binaryNode)

                        // Full analysis: dylibs
                        if doFullAnalysis {
                            let dylibs = await Self.getDylibDependencies(execPath)
                            for (dylibIndex, dylib) in dylibs.prefix(5).enumerated() { // Max 5 dylibs per binary
                                let dylibId = "dylib:\(dylib.path.hashValue)"
                                if !addedDylibs.contains(dylibId) {
                                    addedDylibs.insert(dylibId)
                                    let dylibAngle = angle + Double(dylibIndex + 1) * 0.15
                                    let dylibRadius = radius * 0.25
                                    var dylibNode = GraphNode(
                                        id: dylibId,
                                        type: dylib.path.contains(".framework") ? .framework : .dylib,
                                        label: String(dylib.name.prefix(15)),
                                        details: nil,
                                        path: dylib.path,
                                        riskScore: nil,
                                        persistenceItemId: nil
                                    )
                                    dylibNode.position = CGPoint(
                                        x: centerX + dylibRadius * cos(dylibAngle),
                                        y: centerY + dylibRadius * sin(dylibAngle)
                                    )
                                    nodes.append(dylibNode)
                                }
                                edges.append(GraphEdge(from: execId, to: dylibId, relationship: .loadsDylib))
                            }

                            // Full analysis: network connections (solo per processi attivi)
                            if item.isLoaded {
                                let connections = await Self.getNetworkConnections(for: execPath)
                                for conn in connections.prefix(3) { // Max 3 connections per binary
                                    let netId = "net:\(conn.remoteAddress):\(conn.remotePort)"
                                    let netAngle = angle - 0.2
                                    let netRadius = radius * 0.7
                                    var netNode = GraphNode(
                                        id: netId,
                                        type: .network,
                                        label: conn.displayName,
                                        details: conn.state,
                                        path: nil,
                                        riskScore: nil,
                                        persistenceItemId: nil
                                    )
                                    netNode.position = CGPoint(
                                        x: centerX + netRadius * cos(netAngle),
                                        y: centerY + netRadius * sin(netAngle)
                                    )
                                    nodes.append(netNode)
                                    edges.append(GraphEdge(from: execId, to: netId, relationship: .connectsTo))
                                }
                            }
                        }
                    }

                    edges.append(GraphEdge(from: "item:\(index)", to: execId, relationship: .executes))
                }

                // Aggiorna progress
                let progress = Double(index + 1) / Double(items.count)
                await MainActor.run {
                    graph.analysisProgress = progress * 0.9
                }
            }

            // Aggiorna UI sul main thread
            await MainActor.run {
                graph.nodes = nodes
                graph.edges = edges
                graph.analysisProgress = 1.0
                graph.isAnalyzing = false
            }
        }
    }

    // MARK: - Dylib Analysis

    private static func getDylibDependencies(_ binaryPath: URL) async -> [DylibInfo] {
        let output = await CommandRunner.run(
            "/usr/bin/otool",
            arguments: ["-L", binaryPath.path],
            timeout: 5.0
        )

        var dylibs: [DylibInfo] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let parenIndex = trimmed.firstIndex(of: "(") {
                let path = String(trimmed[..<parenIndex]).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty && path.hasPrefix("/") {
                    let info = DylibInfo(path: path)
                    // Skip system libraries to reduce noise
                    if !info.isSystem {
                        dylibs.append(info)
                    }
                }
            }
        }

        return dylibs
    }

    // MARK: - Network Analysis

    private static func getNetworkConnections(for binaryPath: URL) async -> [NetworkConnection] {
        let pidOutput = await CommandRunner.run(
            "/usr/bin/pgrep",
            arguments: ["-f", binaryPath.lastPathComponent],
            timeout: 3.0
        )

        let pids = pidOutput.components(separatedBy: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        guard let pid = pids.first else { return [] }

        let lsofOutput = await CommandRunner.run(
            "/usr/sbin/lsof",
            arguments: ["-i", "-n", "-P", "-p", String(pid)],
            timeout: 5.0
        )

        return Self.parseLsofOutput(lsofOutput, pid: pid)
    }

    private static func parseLsofOutput(_ output: String, pid: Int) -> [NetworkConnection] {
        var connections: [NetworkConnection] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            guard line.contains("IPv4") || line.contains("IPv6") else { continue }

            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }

            let nameField = String(parts[parts.count - 1])

            if nameField.contains("->") {
                let addressParts = nameField.components(separatedBy: "->")
                if addressParts.count == 2 {
                    let (_, localPort) = Self.parseAddress(addressParts[0])
                    let (remoteAddr, remotePort) = Self.parseAddress(addressParts[1])
                    let state = parts.count >= 10 ? String(parts[parts.count - 2]) : "ESTABLISHED"

                    connections.append(NetworkConnection(
                        localAddress: "*",
                        localPort: localPort,
                        remoteAddress: remoteAddr,
                        remotePort: remotePort,
                        state: state.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: ""),
                        processId: pid
                    ))
                }
            } else if nameField.contains(":") {
                let (addr, port) = Self.parseAddress(nameField)
                connections.append(NetworkConnection(
                    localAddress: addr,
                    localPort: port,
                    remoteAddress: "*",
                    remotePort: 0,
                    state: "LISTEN",
                    processId: pid
                ))
            }
        }

        return connections
    }

    private static func parseAddress(_ addressString: String) -> (String, Int) {
        if addressString.hasPrefix("[") {
            if let closeBracket = addressString.lastIndex(of: "]") {
                let addr = String(addressString[addressString.index(after: addressString.startIndex)..<closeBracket])
                let portStart = addressString.index(after: closeBracket)
                if portStart < addressString.endIndex {
                    let portStr = addressString[addressString.index(after: portStart)...]
                    return (addr, Int(portStr) ?? 0)
                }
                return (addr, 0)
            }
        }

        let parts = addressString.components(separatedBy: ":")
        if parts.count >= 2 {
            let addr = parts.dropLast().joined(separator: ":")
            let port = Int(parts.last ?? "0") ?? 0
            return (addr, port)
        }

        return (addressString, 0)
    }

    private func resetView() {
        withAnimation(.spring()) {
            scale = 1.0
            offset = .zero
            lastOffset = .zero
        }
    }

    // MARK: - Focused Analysis (Single Item)

    private func startFocusedAnalysis() {
        guard let item = appState.focusedGraphItem else { return }

        graph.isAnalyzing = true
        graph.analysisProgress = 0.1

        let width = max(viewSize.width, 800)
        let height = max(viewSize.height, 600)

        Task.detached(priority: .userInitiated) {
            var nodes: [GraphNode] = []
            var edges: [GraphEdge] = []

            let centerX = width / 2
            let centerY = height / 2

            // Central node: the persistence item
            let nodeType: GraphNode.NodeType = {
                switch item.category {
                case .launchAgents: return .launchAgent
                case .launchDaemons: return .launchDaemon
                case .loginItems: return .loginItem
                case .kernelExtensions: return .kext
                case .systemExtensions: return .systemExtension
                case .cronJobs: return .cronJob
                case .shellStartupFiles, .periodicScripts: return .script
                default: return .plist
                }
            }()

            var centralNode = GraphNode(
                id: "item:central",
                type: nodeType,
                label: item.name,
                details: item.identifier,
                path: item.plistPath?.path,
                riskScore: item.riskScore,
                persistenceItemId: item.id
            )
            centralNode.position = CGPoint(x: centerX, y: centerY)
            nodes.append(centralNode)

            await MainActor.run { graph.analysisProgress = 0.2 }

            // Ring 1: Binary (if exists)
            var binaryId: String? = nil
            if let execPath = item.effectiveExecutablePath {
                binaryId = "bin:main"
                var binaryNode = GraphNode(
                    id: binaryId!,
                    type: .binary,
                    label: execPath.lastPathComponent,
                    details: "Executable",
                    path: execPath.path,
                    riskScore: nil,
                    persistenceItemId: nil
                )
                binaryNode.position = CGPoint(x: centerX, y: centerY - 120)
                nodes.append(binaryNode)
                edges.append(GraphEdge(from: "item:central", to: binaryId!, relationship: .executes, details: "Launches"))

                await MainActor.run { graph.analysisProgress = 0.3 }

                // Ring 2: Dylibs (around the binary)
                let dylibs = await Self.getDylibDependencies(execPath)
                let dylibCount = min(dylibs.count, 12) // Limit to 12
                for (i, dylib) in dylibs.prefix(12).enumerated() {
                    let angle = (2.0 * Double.pi * Double(i)) / Double(max(dylibCount, 1)) - Double.pi / 2
                    let radius: CGFloat = 180
                    let dylibId = "dylib:\(i)"
                    var dylibNode = GraphNode(
                        id: dylibId,
                        type: dylib.path.contains(".framework") ? .framework : .dylib,
                        label: String(dylib.name.prefix(20)),
                        details: nil,
                        path: dylib.path,
                        riskScore: nil,
                        persistenceItemId: nil
                    )
                    dylibNode.position = CGPoint(
                        x: centerX + radius * cos(angle),
                        y: centerY - 120 + radius * sin(angle) * 0.6
                    )
                    nodes.append(dylibNode)
                    edges.append(GraphEdge(from: binaryId!, to: dylibId, relationship: .loadsDylib))
                }

                await MainActor.run { graph.analysisProgress = 0.6 }

                // Ring 3: Network connections (if loaded)
                if item.isLoaded {
                    let connections = await Self.getNetworkConnections(for: execPath)
                    for (i, conn) in connections.prefix(6).enumerated() {
                        let angle = Double.pi / 2 + (Double.pi * Double(i)) / Double(max(connections.count, 1))
                        let radius: CGFloat = 150
                        let netId = "net:\(i)"
                        var netNode = GraphNode(
                            id: netId,
                            type: .network,
                            label: conn.displayName,
                            details: conn.state,
                            path: nil,
                            riskScore: nil,
                            persistenceItemId: nil
                        )
                        netNode.position = CGPoint(
                            x: centerX + radius * cos(angle),
                            y: centerY + radius * sin(angle)
                        )
                        nodes.append(netNode)
                        edges.append(GraphEdge(from: binaryId!, to: netId, relationship: .connectsTo, details: conn.state))
                    }
                }
            }

            await MainActor.run { graph.analysisProgress = 0.8 }

            // Parent app (if exists)
            if let parentPath = item.parentAppPath {
                var appNode = GraphNode(
                    id: "app:parent",
                    type: .parentApp,
                    label: parentPath.deletingPathExtension().lastPathComponent,
                    details: "Parent Application",
                    path: parentPath.path,
                    riskScore: nil,
                    persistenceItemId: nil
                )
                appNode.position = CGPoint(x: centerX + 200, y: centerY)
                nodes.append(appNode)
                edges.append(GraphEdge(from: "item:central", to: "app:parent", relationship: .belongsTo, details: "Part of bundle"))
            }

            await MainActor.run {
                graph.nodes = nodes
                graph.edges = edges
                graph.analysisProgress = 1.0
                graph.isAnalyzing = false
            }
        }
    }
}

// MARK: - Graph Canvas

struct GraphCanvas: View {
    @ObservedObject var graph: PersistenceGraph
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let scale: CGFloat
    let offset: CGSize

    var body: some View {
        Canvas { context, size in
            let transform = CGAffineTransform(translationX: offset.width, y: offset.height)
                .scaledBy(x: scale, y: scale)

            // Draw edges
            for edge in graph.edges {
                guard let sourceNode = graph.node(byId: edge.sourceId),
                      let targetNode = graph.node(byId: edge.targetId) else {
                    continue
                }

                let sourcePoint = sourceNode.position.applying(transform)
                let targetPoint = targetNode.position.applying(transform)

                var path = Path()
                path.move(to: sourcePoint)
                path.addLine(to: targetPoint)

                context.stroke(
                    path,
                    with: .color(edge.relationship.color.opacity(0.6)),
                    style: edge.relationship.lineStyle
                )

                // Draw arrow
                drawArrow(context: context, from: sourcePoint, to: targetPoint, color: edge.relationship.color)
            }

            // Draw ALL nodes directly on Canvas (no SwiftUI overlay)
            for node in graph.nodes {
                let pos = node.position.applying(transform)
                let nodeSize: CGFloat = 44 * scale

                // Draw node circle background
                let bgRect = CGRect(x: pos.x - nodeSize/2, y: pos.y - nodeSize/2, width: nodeSize, height: nodeSize)
                context.fill(Circle().path(in: bgRect), with: .color(node.type.color.opacity(0.2)))
                context.stroke(Circle().path(in: bgRect), with: .color(graph.selectedNode?.id == node.id ? .blue : node.type.color), lineWidth: graph.selectedNode?.id == node.id ? 3 : 2)

                // Draw icon as text (simplified)
                let iconText = Text(node.type.iconChar).font(.system(size: 16 * scale)).foregroundColor(node.type.color)
                context.draw(iconText, at: pos)

                // Draw label below
                let labelText = Text(node.label).font(.system(size: 9 * scale, weight: .medium))
                context.draw(labelText, at: CGPoint(x: pos.x, y: pos.y + nodeSize/2 + 10 * scale))

                // Draw risk score if present
                if let risk = node.riskScore, risk > 0 {
                    let riskText = Text("\(risk)").font(.system(size: 8 * scale, weight: .bold)).foregroundColor(.white)
                    let riskBgRect = CGRect(x: pos.x - 10 * scale, y: pos.y + nodeSize/2 + 18 * scale, width: 20 * scale, height: 12 * scale)
                    context.fill(RoundedRectangle(cornerRadius: 3).path(in: riskBgRect), with: .color(riskColor(for: risk)))
                    context.draw(riskText, at: CGPoint(x: pos.x, y: pos.y + nodeSize/2 + 24 * scale))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            // Find tapped node (single click selects)
            let transform = CGAffineTransform(translationX: offset.width, y: offset.height)
                .scaledBy(x: scale, y: scale)

            // Check nodes first
            for node in graph.nodes {
                let pos = node.position.applying(transform)
                let distance = sqrt(pow(location.x - pos.x, 2) + pow(location.y - pos.y, 2))
                if distance < 30 * scale {
                    if graph.selectedNode?.id == node.id {
                        graph.selectedNode = nil
                    } else {
                        graph.selectedNode = node
                    }
                    graph.selectedEdge = nil
                    return
                }
            }

            // Check edges
            for edge in graph.edges {
                guard let sourceNode = graph.node(byId: edge.sourceId),
                      let targetNode = graph.node(byId: edge.targetId) else {
                    continue
                }

                let sourcePoint = sourceNode.position.applying(transform)
                let targetPoint = targetNode.position.applying(transform)

                // Calculate distance from point to line segment
                let edgeDistance = distanceToLineSegment(point: location, lineStart: sourcePoint, lineEnd: targetPoint)
                if edgeDistance < 15 * scale {
                    if graph.selectedEdge?.id == edge.id {
                        graph.selectedEdge = nil
                    } else {
                        graph.selectedEdge = edge
                    }
                    graph.selectedNode = nil
                    return
                }
            }

            graph.selectedNode = nil
            graph.selectedEdge = nil
        }
        .onTapGesture(count: 2) { location in
            // Double-click opens detail window
            let transform = CGAffineTransform(translationX: offset.width, y: offset.height)
                .scaledBy(x: scale, y: scale)

            // Check nodes first
            for node in graph.nodes {
                let pos = node.position.applying(transform)
                let distance = sqrt(pow(location.x - pos.x, 2) + pow(location.y - pos.y, 2))
                if distance < 30 * scale {
                    openNodeDetailWindow(node: node)
                    return
                }
            }

            // Check edges
            for edge in graph.edges {
                guard let sourceNode = graph.node(byId: edge.sourceId),
                      let targetNode = graph.node(byId: edge.targetId) else {
                    continue
                }

                let sourcePoint = sourceNode.position.applying(transform)
                let targetPoint = targetNode.position.applying(transform)

                let edgeDistance = distanceToLineSegment(point: location, lineStart: sourcePoint, lineEnd: targetPoint)
                if edgeDistance < 15 * scale {
                    openEdgeDetailWindow(edge: edge, sourceNode: sourceNode, targetNode: targetNode)
                    return
                }
            }
        }
    }

    // MARK: - Open Detail Windows

    private func openNodeDetailWindow(node: GraphNode) {
        appState.graphDetailNode = node
        appState.graphDetailEdge = nil
        appState.graphDetailSourceNode = nil
        appState.graphDetailTargetNode = nil

        // Find linked persistence item if available
        if let itemId = node.persistenceItemId {
            appState.graphDetailPersistenceItem = appState.items.first { $0.id == itemId }
        } else {
            appState.graphDetailPersistenceItem = nil
        }

        openWindow(id: "graph-detail-window")
    }

    private func openEdgeDetailWindow(edge: GraphEdge, sourceNode: GraphNode, targetNode: GraphNode) {
        appState.graphDetailEdge = edge
        appState.graphDetailNode = nil
        appState.graphDetailSourceNode = sourceNode
        appState.graphDetailTargetNode = targetNode

        // Find linked persistence item from source node
        if let itemId = sourceNode.persistenceItemId {
            appState.graphDetailPersistenceItem = appState.items.first { $0.id == itemId }
        } else {
            appState.graphDetailPersistenceItem = nil
        }

        openWindow(id: "graph-detail-window")
    }

    // MARK: - Distance Calculation

    private func distanceToLineSegment(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lengthSquared = dx * dx + dy * dy

        if lengthSquared == 0 {
            // Line is a point
            return sqrt(pow(point.x - lineStart.x, 2) + pow(point.y - lineStart.y, 2))
        }

        // Parameter t for closest point on line
        var t = ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lengthSquared
        t = max(0, min(1, t))

        // Closest point on segment
        let closestX = lineStart.x + t * dx
        let closestY = lineStart.y + t * dy

        return sqrt(pow(point.x - closestX, 2) + pow(point.y - closestY, 2))
    }

    private func riskColor(for score: Int) -> Color {
        switch score {
        case 0..<25: return .green
        case 25..<50: return .yellow
        case 50..<75: return .orange
        default: return .red
        }
    }

    private func drawArrow(context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let arrowLength: CGFloat = 10 * scale
        let arrowAngle: CGFloat = .pi / 6

        // Calculate arrow position (slightly before the target)
        let distance = sqrt(pow(to.x - from.x, 2) + pow(to.y - from.y, 2))
        let ratio = (distance - 25 * scale) / distance
        let arrowTip = CGPoint(
            x: from.x + (to.x - from.x) * ratio,
            y: from.y + (to.y - from.y) * ratio
        )

        var arrowPath = Path()
        arrowPath.move(to: arrowTip)
        arrowPath.addLine(to: CGPoint(
            x: arrowTip.x - arrowLength * cos(angle - arrowAngle),
            y: arrowTip.y - arrowLength * sin(angle - arrowAngle)
        ))
        arrowPath.move(to: arrowTip)
        arrowPath.addLine(to: CGPoint(
            x: arrowTip.x - arrowLength * cos(angle + arrowAngle),
            y: arrowTip.y - arrowLength * sin(angle + arrowAngle)
        ))

        context.stroke(arrowPath, with: .color(color), lineWidth: 2 * scale)
    }
}

// MARK: - Node View

struct NodeView: View {
    let node: GraphNode
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            // Icon
            ZStack {
                Circle()
                    .fill(node.type.color.opacity(0.2))
                    .frame(width: 44, height: 44)

                Circle()
                    .stroke(isSelected ? Color.accentColor : node.type.color, lineWidth: isSelected ? 3 : 2)
                    .frame(width: 44, height: 44)

                Image(systemName: node.type.icon)
                    .font(.system(size: 18))
                    .foregroundColor(node.type.color)
            }

            // Label
            Text(node.label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 80)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                .cornerRadius(4)

            // Risk score badge if present
            if let risk = node.riskScore, risk > 0 {
                Text("\(risk)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(riskColor(for: risk))
                    .cornerRadius(4)
            }
        }
        .shadow(color: isSelected ? .accentColor.opacity(0.5) : .clear, radius: 8)
    }

    private func riskColor(for score: Int) -> Color {
        switch score {
        case 0..<25: return .green
        case 25..<50: return .yellow
        case 50..<75: return .orange
        default: return .red
        }
    }
}

// MARK: - Supporting Views

struct EmptyGraphView: View {
    let onAnalyze: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("Persistence Graph")
                .font(.title)
                .fontWeight(.bold)

            Text("Visualize relationships between persistence mechanisms,\nbinaries, libraries, and network connections.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Button(action: onAnalyze) {
                Label("Build Graph", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

struct AnalyzingView: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Analyzing Relationships...")
                .font(.headline)

            ProgressView(value: progress)
                .frame(width: 200)

            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct GraphStatsPanel: View {
    let stats: GraphStatistics

    var body: some View {
        HStack(spacing: 16) {
            StatItem(icon: "circle.fill", label: "Nodes", value: "\(stats.totalNodes)")
            StatItem(icon: "arrow.right", label: "Edges", value: "\(stats.totalEdges)")
            if stats.networkConnections > 0 {
                StatItem(icon: "network", label: "Network", value: "\(stats.networkConnections)", color: .red)
            }
            if stats.dylibCount > 0 {
                StatItem(icon: "shippingbox", label: "Dylibs", value: "\(stats.dylibCount)", color: .orange)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }
}

struct StatItem: View {
    let icon: String
    let label: String
    let value: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.caption)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct GraphControlsPanel: View {
    @Binding var showStats: Bool
    @Binding var scale: CGFloat
    let onReset: () -> Void
    let onRefresh: () -> Void
    let isAnalyzing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { showStats.toggle() }) {
                Image(systemName: showStats ? "chart.bar.fill" : "chart.bar")
            }
            .help("Toggle statistics")

            Divider().frame(height: 20)

            Button(action: { scale = max(0.3, scale - 0.2) }) {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out")

            Text("\(Int(scale * 100))%")
                .font(.caption)
                .frame(width: 40)

            Button(action: { scale = min(3.0, scale + 0.2) }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in")

            Divider().frame(height: 20)

            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Reset view")

            Button(action: onRefresh) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .disabled(isAnalyzing)
            .help("Refresh graph")
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }
}

struct NodeDetailPanel: View {
    let node: GraphNode
    @ObservedObject var graph: PersistenceGraph
    @EnvironmentObject var appState: AppState

    private var persistenceItem: PersistenceItem? {
        guard let itemId = node.persistenceItemId else { return nil }
        return appState.items.first { $0.id == itemId }
    }

    private var outgoingEdges: [GraphEdge] {
        graph.edges(from: node.id)
    }

    private var incomingEdges: [GraphEdge] {
        graph.edges(to: node.id)
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Image(systemName: node.type.icon)
                    .font(.title2)
                    .foregroundColor(node.type.color)
                    .frame(width: 36, height: 36)
                    .background(node.type.color.opacity(0.2))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.label)
                        .font(.headline)
                    Text(node.type.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let risk = node.riskScore, risk > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Risk: \(risk)")
                    }
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(riskColor(for: risk))
                    .cornerRadius(6)
                }

                Button(action: { graph.selectedNode = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Scrollable content with all details
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Node Info
                    DetailSectionInline(title: "Node Info", icon: "info.circle") {
                        DetailRowInline(label: "ID", value: node.id)
                        if let path = node.path {
                            DetailRowInline(label: "Path", value: path, copyable: true)
                        }
                        if let details = node.details {
                            DetailRowInline(label: "Details", value: details)
                        }
                        DetailRowInline(label: "Connections", value: "\(outgoingEdges.count) out, \(incomingEdges.count) in")
                    }

                    // Persistence Item details (if linked)
                    if let item = persistenceItem {
                        DetailSectionInline(title: "Persistence Item", icon: "doc.text.fill") {
                            DetailRowInline(label: "Name", value: item.name)
                            DetailRowInline(label: "Identifier", value: item.identifier)
                            DetailRowInline(label: "Category", value: item.category.displayName)
                            DetailRowInline(label: "Trust", value: item.trustLevel.displayName, color: item.trustLevel.color)
                            DetailRowInline(label: "Enabled", value: item.isEnabled ? "Yes" : "No", color: item.isEnabled ? .green : .secondary)
                            DetailRowInline(label: "Loaded", value: item.isLoaded ? "Yes" : "No", color: item.isLoaded ? .green : .secondary)
                            if let version = item.version {
                                DetailRowInline(label: "Version", value: version)
                            }
                        }

                        // Paths
                        DetailSectionInline(title: "File Paths", icon: "folder") {
                            if let plist = item.plistPath {
                                DetailRowInline(label: "Plist", value: plist.path, copyable: true)
                            }
                            if let exec = item.executablePath {
                                DetailRowInline(label: "Executable", value: exec.path, copyable: true)
                            }
                            if let parent = item.parentAppPath {
                                DetailRowInline(label: "Parent App", value: parent.path, copyable: true)
                            }
                            if let workDir = item.workingDirectory {
                                DetailRowInline(label: "Working Dir", value: workDir)
                            }
                        }

                        // Signature
                        if let sig = item.signatureInfo {
                            DetailSectionInline(title: "Code Signature", icon: "checkmark.seal") {
                                DetailRowInline(label: "Signed", value: sig.isSigned ? "Yes" : "No", color: sig.isSigned ? .green : .red)
                                if let org = sig.organizationName {
                                    DetailRowInline(label: "Organization", value: org)
                                }
                                if let team = sig.teamIdentifier {
                                    DetailRowInline(label: "Team ID", value: team)
                                }
                                DetailRowInline(label: "Apple Signed", value: sig.isAppleSigned ? "Yes" : "No", color: sig.isAppleSigned ? .green : .secondary)
                                DetailRowInline(label: "Notarized", value: sig.isNotarized ? "Yes" : "No", color: sig.isNotarized ? .green : .secondary)
                            }
                        }

                        // Plist Config
                        if item.runAtLoad != nil || item.keepAlive != nil || item.programArguments != nil {
                            DetailSectionInline(title: "Plist Config", icon: "gearshape") {
                                if let runAtLoad = item.runAtLoad {
                                    DetailRowInline(label: "Run At Load", value: runAtLoad ? "Yes" : "No", color: runAtLoad ? .orange : .secondary)
                                }
                                if let keepAlive = item.keepAlive {
                                    DetailRowInline(label: "Keep Alive", value: keepAlive ? "Yes" : "No", color: keepAlive ? .orange : .secondary)
                                }
                                if let args = item.programArguments, !args.isEmpty {
                                    DetailRowInline(label: "Arguments", value: args.joined(separator: " "))
                                }
                            }
                        }

                        // Timestamps
                        DetailSectionInline(title: "Timestamps", icon: "clock") {
                            if let created = item.plistCreatedAt {
                                DetailRowInline(label: "Plist Created", value: dateFormatter.string(from: created))
                            }
                            if let modified = item.plistModifiedAt {
                                DetailRowInline(label: "Plist Modified", value: dateFormatter.string(from: modified))
                            }
                            if let binCreated = item.binaryCreatedAt {
                                DetailRowInline(label: "Binary Created", value: dateFormatter.string(from: binCreated))
                            }
                            if let binExec = item.binaryLastExecutedAt {
                                DetailRowInline(label: "Last Executed", value: dateFormatter.string(from: binExec))
                            }
                            DetailRowInline(label: "Discovered", value: dateFormatter.string(from: item.discoveredAt))
                        }

                        // Risk Assessment
                        if let riskScore = item.riskScore {
                            DetailSectionInline(title: "Risk Assessment", icon: "exclamationmark.triangle") {
                                HStack {
                                    Text("Score")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(width: 80, alignment: .trailing)

                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(Color.secondary.opacity(0.2))
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(riskColor(for: riskScore))
                                                .frame(width: geo.size.width * CGFloat(riskScore) / 100)
                                        }
                                    }
                                    .frame(height: 8)
                                    .frame(maxWidth: 150)

                                    Text("\(riskScore)/100")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(riskColor(for: riskScore))
                                }

                                if let details = item.riskDetails, !details.isEmpty {
                                    ForEach(details.prefix(5), id: \.factor) { detail in
                                        HStack {
                                            Circle()
                                                .fill(riskDetailColor(for: detail.points))
                                                .frame(width: 6, height: 6)
                                            Text(detail.factor)
                                                .font(.caption)
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

                        // Signed-but-Dangerous
                        if let flags = item.signedButDangerousFlags, !flags.isEmpty {
                            DetailSectionInline(title: "Signed-but-Dangerous", icon: "exclamationmark.shield") {
                                ForEach(flags.prefix(3)) { flag in
                                    HStack(alignment: .top) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(flag.title)
                                                .font(.caption)
                                                .fontWeight(.medium)
                                            Text(flag.description)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Text("+\(flag.points)")
                                            .font(.caption2)
                                            .fontWeight(.bold)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .frame(maxHeight: 350)
        }
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding()
    }

    private func riskColor(for score: Int) -> Color {
        switch score {
        case 0..<25: return .green
        case 25..<50: return .yellow
        case 50..<75: return .orange
        default: return .red
        }
    }

    private func riskDetailColor(for points: Int) -> Color {
        switch points {
        case 0..<10: return .yellow
        case 10..<20: return .orange
        default: return .red
        }
    }
}

// MARK: - Inline Detail Components

struct DetailSectionInline<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
            }

            VStack(alignment: .leading, spacing: 4) {
                content
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(6)
        }
    }
}

struct DetailRowInline: View {
    let label: String
    let value: String
    var copyable: Bool = false
    var color: Color? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)

            Text(value)
                .font(.caption)
                .foregroundColor(color)
                .lineLimit(2)
                .textSelection(.enabled)

            Spacer()

            if copyable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
    }
}

struct EdgeDetailPanel: View {
    let edge: GraphEdge
    @ObservedObject var graph: PersistenceGraph
    @EnvironmentObject var appState: AppState

    private var sourceNode: GraphNode? {
        graph.node(byId: edge.sourceId)
    }

    private var targetNode: GraphNode? {
        graph.node(byId: edge.targetId)
    }

    private var sourcePersistenceItem: PersistenceItem? {
        guard let itemId = sourceNode?.persistenceItemId else { return nil }
        return appState.items.first { $0.id == itemId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title2)
                    .foregroundColor(edge.relationship.color)
                    .frame(width: 36, height: 36)
                    .background(edge.relationship.color.opacity(0.2))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(edge.relationship.rawValue.capitalized)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text(sourceNode?.label ?? "?")
                            .font(.caption)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundColor(edge.relationship.color)
                        Text(targetNode?.label ?? "?")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { graph.selectedEdge = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Relationship Info
                    DetailSectionInline(title: "Relationship", icon: "link") {
                        DetailRowInline(label: "Type", value: edge.relationship.rawValue)
                        DetailRowInline(label: "Edge ID", value: edge.id)
                        if let details = edge.details {
                            DetailRowInline(label: "Details", value: details)
                        }
                    }

                    // Source Node
                    if let source = sourceNode {
                        DetailSectionInline(title: "Source Node", icon: source.type.icon) {
                            DetailRowInline(label: "Label", value: source.label)
                            DetailRowInline(label: "Type", value: source.type.rawValue)
                            if let path = source.path {
                                DetailRowInline(label: "Path", value: path, copyable: true)
                            }
                            if let risk = source.riskScore {
                                DetailRowInline(label: "Risk", value: "\(risk)/100", color: riskColor(for: risk))
                            }
                        }
                    }

                    // Target Node
                    if let target = targetNode {
                        DetailSectionInline(title: "Target Node", icon: target.type.icon) {
                            DetailRowInline(label: "Label", value: target.label)
                            DetailRowInline(label: "Type", value: target.type.rawValue)
                            if let path = target.path {
                                DetailRowInline(label: "Path", value: path, copyable: true)
                            }
                        }
                    }

                    // Source Persistence Item (if available)
                    if let item = sourcePersistenceItem {
                        DetailSectionInline(title: "Persistence Item", icon: "doc.text.fill") {
                            DetailRowInline(label: "Name", value: item.name)
                            DetailRowInline(label: "Category", value: item.category.displayName)
                            DetailRowInline(label: "Trust", value: item.trustLevel.displayName, color: item.trustLevel.color)
                            DetailRowInline(label: "Enabled", value: item.isEnabled ? "Yes" : "No", color: item.isEnabled ? .green : .secondary)
                        }

                        if let sig = item.signatureInfo {
                            DetailSectionInline(title: "Signature", icon: "checkmark.seal") {
                                DetailRowInline(label: "Signed", value: sig.isSigned ? "Yes" : "No", color: sig.isSigned ? .green : .red)
                                if let org = sig.organizationName {
                                    DetailRowInline(label: "Organization", value: org)
                                }
                                DetailRowInline(label: "Apple Signed", value: sig.isAppleSigned ? "Yes" : "No", color: sig.isAppleSigned ? .green : .secondary)
                            }
                        }
                    }
                }
                .padding()
            }
            .frame(maxHeight: 300)
        }
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .padding()
    }

    private func riskColor(for score: Int) -> Color {
        switch score {
        case 0..<25: return .green
        case 25..<50: return .yellow
        case 50..<75: return .orange
        default: return .red
        }
    }
}

struct GraphLegend: View {
    let nodeTypes: [GraphNode.NodeType] = [
        .launchAgent, .launchDaemon, .binary, .dylib, .network, .parentApp
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legend")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            ForEach(nodeTypes, id: \.self) { type in
                HStack(spacing: 6) {
                    Circle()
                        .fill(type.color)
                        .frame(width: 8, height: 8)
                    Text(type.rawValue)
                        .font(.caption2)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
    }
}

// MARK: - Preview

#Preview {
    GraphView()
        .environmentObject(AppState.shared)
        .frame(width: 800, height: 600)
}
