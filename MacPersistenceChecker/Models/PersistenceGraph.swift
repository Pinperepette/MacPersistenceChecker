import Foundation
import SwiftUI

// MARK: - Graph Node

/// Represents a node in the persistence graph
struct GraphNode: Identifiable, Equatable, Hashable {
    let id: String
    let type: NodeType
    let label: String
    let details: String?
    let path: String?
    let riskScore: Int?

    /// Position for visualization (set by layout algorithm)
    var position: CGPoint = .zero

    /// Whether this node is currently selected
    var isSelected: Bool = false

    /// Reference to original PersistenceItem if applicable
    let persistenceItemId: UUID?

    enum NodeType: String, Codable, CaseIterable {
        case launchAgent = "LaunchAgent"
        case launchDaemon = "LaunchDaemon"
        case binary = "Binary"
        case dylib = "Dylib"
        case framework = "Framework"
        case network = "Network"
        case parentApp = "Application"
        case kext = "Kext"
        case systemExtension = "SystemExtension"
        case loginItem = "LoginItem"
        case cronJob = "CronJob"
        case script = "Script"
        case plist = "Plist"
        case unknown = "Unknown"

        var color: Color {
            switch self {
            case .launchAgent, .launchDaemon: return .purple
            case .binary, .script: return .blue
            case .dylib, .framework: return .orange
            case .network: return .red
            case .parentApp: return .green
            case .kext, .systemExtension: return .pink
            case .loginItem: return .teal
            case .cronJob: return .yellow
            case .plist: return .gray
            case .unknown: return .secondary
            }
        }

        var icon: String {
            switch self {
            case .launchAgent: return "person.badge.clock"
            case .launchDaemon: return "server.rack"
            case .binary: return "terminal"
            case .dylib, .framework: return "shippingbox"
            case .network: return "network"
            case .parentApp: return "app.badge"
            case .kext: return "cpu"
            case .systemExtension: return "puzzlepiece.extension"
            case .loginItem: return "person.crop.circle.badge.checkmark"
            case .cronJob: return "clock.badge"
            case .script: return "scroll"
            case .plist: return "doc.text"
            case .unknown: return "questionmark.circle"
            }
        }

        /// Simple character for Canvas rendering (fallback when SF Symbols aren't available in Canvas text)
        var iconChar: String {
            switch self {
            case .launchAgent: return "LA"
            case .launchDaemon: return "LD"
            case .binary: return "⬢"
            case .dylib, .framework: return "📦"
            case .network: return "🌐"
            case .parentApp: return "📱"
            case .kext: return "⚙️"
            case .systemExtension: return "🧩"
            case .loginItem: return "👤"
            case .cronJob: return "⏰"
            case .script: return "📜"
            case .plist: return "📄"
            case .unknown: return "❓"
            }
        }
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: GraphNode, rhs: GraphNode) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Graph Edge

/// Represents a directed edge between two nodes
struct GraphEdge: Identifiable, Equatable, Hashable {
    let id: String
    let sourceId: String
    let targetId: String
    let relationship: RelationshipType
    let details: String?

    enum RelationshipType: String, Codable {
        case executes = "executes"
        case loadsDylib = "loads"
        case linksFramework = "links"
        case connectsTo = "connects to"
        case belongsTo = "belongs to"
        case spawns = "spawns"
        case dependsOn = "depends on"
        case writesTo = "writes to"
        case readsFrom = "reads from"

        var color: Color {
            switch self {
            case .executes: return .blue
            case .loadsDylib, .linksFramework: return .orange
            case .connectsTo: return .red
            case .belongsTo: return .green
            case .spawns: return .purple
            case .dependsOn: return .gray
            case .writesTo, .readsFrom: return .yellow
            }
        }

        var lineStyle: StrokeStyle {
            switch self {
            case .connectsTo:
                return StrokeStyle(lineWidth: 2, dash: [5, 3])
            case .dependsOn:
                return StrokeStyle(lineWidth: 1, dash: [3, 2])
            default:
                return StrokeStyle(lineWidth: 2)
            }
        }
    }

    init(from sourceId: String, to targetId: String, relationship: RelationshipType, details: String? = nil) {
        self.id = "\(sourceId)->\(targetId):\(relationship.rawValue)"
        self.sourceId = sourceId
        self.targetId = targetId
        self.relationship = relationship
        self.details = details
    }
}

// MARK: - Persistence Graph

/// The complete graph structure
class PersistenceGraph: ObservableObject {
    @Published var nodes: [GraphNode] = []
    @Published var edges: [GraphEdge] = []
    @Published var selectedNode: GraphNode? = nil
    @Published var isAnalyzing: Bool = false
    @Published var analysisProgress: Double = 0

    /// Get node by ID
    func node(byId id: String) -> GraphNode? {
        nodes.first { $0.id == id }
    }

    /// Get all edges from a node
    func edges(from nodeId: String) -> [GraphEdge] {
        edges.filter { $0.sourceId == nodeId }
    }

    /// Get all edges to a node
    func edges(to nodeId: String) -> [GraphEdge] {
        edges.filter { $0.targetId == nodeId }
    }

    /// Get connected nodes (both directions)
    func connectedNodes(to nodeId: String) -> [GraphNode] {
        let connectedIds = Set(
            edges.filter { $0.sourceId == nodeId }.map { $0.targetId } +
            edges.filter { $0.targetId == nodeId }.map { $0.sourceId }
        )
        return nodes.filter { connectedIds.contains($0.id) }
    }

    /// Add a node if it doesn't exist
    @discardableResult
    func addNode(_ node: GraphNode) -> GraphNode {
        if let existing = nodes.first(where: { $0.id == node.id }) {
            return existing
        }
        nodes.append(node)
        return node
    }

    /// Add an edge if it doesn't exist
    func addEdge(_ edge: GraphEdge) {
        if !edges.contains(where: { $0.id == edge.id }) {
            edges.append(edge)
        }
    }

    /// Clear the graph
    func clear() {
        nodes.removeAll()
        edges.removeAll()
        selectedNode = nil
    }

    /// Calculate layout positions using force-directed algorithm
    func calculateLayout(size: CGSize) {
        guard !nodes.isEmpty else { return }

        let centerX = size.width / 2
        let centerY = size.height / 2
        let radius = min(size.width, size.height) * 0.35

        // Initial circular layout
        for (index, _) in nodes.enumerated() {
            let angle = (2 * .pi * Double(index)) / Double(nodes.count)
            nodes[index].position = CGPoint(
                x: centerX + radius * cos(angle),
                y: centerY + radius * sin(angle)
            )
        }

        // Force-directed iterations
        let iterations = 50
        let repulsion: CGFloat = 5000
        let attraction: CGFloat = 0.05
        let damping: CGFloat = 0.85

        var velocities = [String: CGPoint]()
        for node in nodes {
            velocities[node.id] = .zero
        }

        for _ in 0..<iterations {
            // Calculate forces
            var forces = [String: CGPoint]()
            for node in nodes {
                forces[node.id] = .zero
            }

            // Repulsion between all nodes
            for i in 0..<nodes.count {
                for j in (i+1)..<nodes.count {
                    let dx = nodes[j].position.x - nodes[i].position.x
                    let dy = nodes[j].position.y - nodes[i].position.y
                    let distance = max(sqrt(dx*dx + dy*dy), 1)
                    let force = repulsion / (distance * distance)

                    let fx = (dx / distance) * force
                    let fy = (dy / distance) * force

                    forces[nodes[i].id]!.x -= fx
                    forces[nodes[i].id]!.y -= fy
                    forces[nodes[j].id]!.x += fx
                    forces[nodes[j].id]!.y += fy
                }
            }

            // Attraction along edges
            for edge in edges {
                guard let sourceIdx = nodes.firstIndex(where: { $0.id == edge.sourceId }),
                      let targetIdx = nodes.firstIndex(where: { $0.id == edge.targetId }) else {
                    continue
                }

                let dx = nodes[targetIdx].position.x - nodes[sourceIdx].position.x
                let dy = nodes[targetIdx].position.y - nodes[sourceIdx].position.y

                let fx = dx * attraction
                let fy = dy * attraction

                forces[nodes[sourceIdx].id]!.x += fx
                forces[nodes[sourceIdx].id]!.y += fy
                forces[nodes[targetIdx].id]!.x -= fx
                forces[nodes[targetIdx].id]!.y -= fy
            }

            // Center gravity
            for i in 0..<nodes.count {
                let dx = centerX - nodes[i].position.x
                let dy = centerY - nodes[i].position.y
                forces[nodes[i].id]!.x += dx * 0.01
                forces[nodes[i].id]!.y += dy * 0.01
            }

            // Apply forces
            for i in 0..<nodes.count {
                let nodeId = nodes[i].id
                velocities[nodeId]!.x = (velocities[nodeId]!.x + forces[nodeId]!.x) * damping
                velocities[nodeId]!.y = (velocities[nodeId]!.y + forces[nodeId]!.y) * damping

                nodes[i].position.x += velocities[nodeId]!.x
                nodes[i].position.y += velocities[nodeId]!.y

                // Keep within bounds
                nodes[i].position.x = max(50, min(size.width - 50, nodes[i].position.x))
                nodes[i].position.y = max(50, min(size.height - 50, nodes[i].position.y))
            }
        }
    }

    /// Get statistics about the graph
    var statistics: GraphStatistics {
        GraphStatistics(
            totalNodes: nodes.count,
            totalEdges: edges.count,
            nodesByType: Dictionary(grouping: nodes, by: { $0.type }).mapValues { $0.count },
            edgesByType: Dictionary(grouping: edges, by: { $0.relationship }).mapValues { $0.count },
            networkConnections: nodes.filter { $0.type == .network }.count,
            dylibCount: nodes.filter { $0.type == .dylib || $0.type == .framework }.count
        )
    }
}

// MARK: - Graph Statistics

struct GraphStatistics {
    let totalNodes: Int
    let totalEdges: Int
    let nodesByType: [GraphNode.NodeType: Int]
    let edgesByType: [GraphEdge.RelationshipType: Int]
    let networkConnections: Int
    let dylibCount: Int
}

// MARK: - Network Connection Info

struct NetworkConnection: Identifiable {
    let id = UUID()
    let localAddress: String
    let localPort: Int
    let remoteAddress: String
    let remotePort: Int
    let state: String
    let processId: Int

    var displayName: String {
        if remoteAddress == "*" || remoteAddress.isEmpty {
            return "Listen :\(localPort)"
        }
        return "\(remoteAddress):\(remotePort)"
    }
}

// MARK: - Dylib Info

struct DylibInfo: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let isSystem: Bool

    init(path: String) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.isSystem = path.hasPrefix("/System/") ||
                        path.hasPrefix("/usr/lib/") ||
                        path.hasPrefix("/Library/Apple/")
    }
}
