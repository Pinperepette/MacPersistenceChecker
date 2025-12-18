import Foundation

/// Analyzes persistence items and builds a relationship graph
final class GraphAnalyzer {

    let graph: PersistenceGraph

    init(graph: PersistenceGraph = PersistenceGraph()) {
        self.graph = graph
    }

    // MARK: - Main Analysis

    /// Analyze all persistence items and build the graph
    @MainActor
    func analyze(items: [PersistenceItem]) async -> PersistenceGraph {
        graph.clear()
        graph.isAnalyzing = true
        graph.analysisProgress = 0

        let totalSteps = Double(items.count)
        var completedSteps = 0.0

        for item in items {
            // Create node for the persistence item
            let itemNode = createNode(for: item)
            graph.addNode(itemNode)

            // Analyze executable
            if let execPath = item.effectiveExecutablePath {
                await analyzeExecutable(execPath, parentNode: itemNode, item: item)
            }

            // Analyze parent app
            if let parentPath = item.parentAppPath {
                analyzeParentApp(parentPath, childNode: itemNode)
            }

            completedSteps += 1
            graph.analysisProgress = completedSteps / totalSteps
        }

        graph.isAnalyzing = false
        graph.analysisProgress = 1.0

        return graph
    }

    // MARK: - Node Creation

    private func createNode(for item: PersistenceItem) -> GraphNode {
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

        return GraphNode(
            id: "item:\(item.id.uuidString)",
            type: nodeType,
            label: item.name,
            details: item.identifier,
            path: item.plistPath?.path,
            riskScore: item.riskScore,
            persistenceItemId: item.id
        )
    }

    // MARK: - Executable Analysis

    private func analyzeExecutable(_ execPath: URL, parentNode: GraphNode, item: PersistenceItem) async {
        let execId = "binary:\(execPath.path.hashValue)"

        // Create binary node
        let binaryNode = GraphNode(
            id: execId,
            type: .binary,
            label: execPath.lastPathComponent,
            details: nil,
            path: execPath.path,
            riskScore: nil,
            persistenceItemId: nil
        )
        graph.addNode(binaryNode)

        // Edge: plist -> binary
        graph.addEdge(GraphEdge(
            from: parentNode.id,
            to: execId,
            relationship: .executes,
            details: "Launches executable"
        ))

        // Analyze dylibs
        await analyzeDylibs(for: execPath, binaryNode: binaryNode)

        // Analyze network connections (only for running processes)
        if item.isLoaded {
            await analyzeNetworkConnections(for: execPath, binaryNode: binaryNode)
        }
    }

    // MARK: - Dylib Analysis

    private func analyzeDylibs(for binaryPath: URL, binaryNode: GraphNode) async {
        let dylibs = await getDylibDependencies(binaryPath)

        for dylib in dylibs {
            // Skip system libraries to reduce noise (optional: make this configurable)
            if dylib.isSystem {
                continue
            }

            let dylibId = "dylib:\(dylib.path.hashValue)"

            let dylibNode = GraphNode(
                id: dylibId,
                type: dylib.path.contains(".framework") ? .framework : .dylib,
                label: dylib.name,
                details: nil,
                path: dylib.path,
                riskScore: nil,
                persistenceItemId: nil
            )
            graph.addNode(dylibNode)

            graph.addEdge(GraphEdge(
                from: binaryNode.id,
                to: dylibId,
                relationship: dylib.path.contains(".framework") ? .linksFramework : .loadsDylib,
                details: nil
            ))
        }
    }

    /// Get dylib dependencies using otool -L
    private func getDylibDependencies(_ binaryPath: URL) async -> [DylibInfo] {
        let output = await CommandRunner.run(
            "/usr/bin/otool",
            arguments: ["-L", binaryPath.path],
            timeout: 10.0
        )

        var dylibs: [DylibInfo] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() { // First line is the binary itself
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Parse: /path/to/lib.dylib (compatibility version X, current version Y)
            if let parenIndex = trimmed.firstIndex(of: "(") {
                let path = String(trimmed[..<parenIndex]).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty && path.hasPrefix("/") {
                    dylibs.append(DylibInfo(path: path))
                }
            }
        }

        return dylibs
    }

    // MARK: - Network Analysis

    private func analyzeNetworkConnections(for binaryPath: URL, binaryNode: GraphNode) async {
        let connections = await getNetworkConnections(for: binaryPath)

        for connection in connections {
            let networkId = "net:\(connection.remoteAddress):\(connection.remotePort)"

            let networkNode = GraphNode(
                id: networkId,
                type: .network,
                label: connection.displayName,
                details: connection.state,
                path: nil,
                riskScore: nil,
                persistenceItemId: nil
            )
            graph.addNode(networkNode)

            graph.addEdge(GraphEdge(
                from: binaryNode.id,
                to: networkId,
                relationship: .connectsTo,
                details: connection.state
            ))
        }
    }

    /// Get network connections for a binary using lsof
    private func getNetworkConnections(for binaryPath: URL) async -> [NetworkConnection] {
        // First find the PID for this binary
        let pidOutput = await CommandRunner.run(
            "/usr/bin/pgrep",
            arguments: ["-f", binaryPath.lastPathComponent],
            timeout: 5.0
        )

        let pids = pidOutput.components(separatedBy: "\n")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        guard !pids.isEmpty else { return [] }

        var allConnections: [NetworkConnection] = []

        for pid in pids.prefix(3) { // Limit to first 3 PIDs
            let lsofOutput = await CommandRunner.run(
                "/usr/sbin/lsof",
                arguments: ["-i", "-n", "-P", "-p", String(pid)],
                timeout: 10.0
            )

            let connections = parseLsofOutput(lsofOutput, pid: pid)
            allConnections.append(contentsOf: connections)
        }

        return allConnections
    }

    /// Parse lsof output for network connections
    private func parseLsofOutput(_ output: String, pid: Int) -> [NetworkConnection] {
        var connections: [NetworkConnection] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            // Skip header and non-network lines
            guard line.contains("IPv4") || line.contains("IPv6") else { continue }

            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }

            // Parse the NAME column which contains address info
            let nameField = String(parts[parts.count - 1])

            if nameField.contains("->") {
                // Established connection: local->remote
                let addressParts = nameField.components(separatedBy: "->")
                if addressParts.count == 2 {
                    let (localAddr, localPort) = parseAddress(addressParts[0])
                    let (remoteAddr, remotePort) = parseAddress(addressParts[1])

                    // Get state if available
                    let state = parts.count >= 10 ? String(parts[parts.count - 2]) : "ESTABLISHED"

                    connections.append(NetworkConnection(
                        localAddress: localAddr,
                        localPort: localPort,
                        remoteAddress: remoteAddr,
                        remotePort: remotePort,
                        state: state.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: ""),
                        processId: pid
                    ))
                }
            } else if nameField.contains(":") {
                // Listening socket
                let (addr, port) = parseAddress(nameField)
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

    /// Parse address:port string
    private func parseAddress(_ addressString: String) -> (String, Int) {
        // Handle IPv6 addresses like [::1]:8080
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

        // IPv4 or hostname: addr:port
        let parts = addressString.components(separatedBy: ":")
        if parts.count >= 2 {
            let addr = parts.dropLast().joined(separator: ":")
            let port = Int(parts.last ?? "0") ?? 0
            return (addr, port)
        }

        return (addressString, 0)
    }

    // MARK: - Parent App Analysis

    private func analyzeParentApp(_ parentPath: URL, childNode: GraphNode) {
        let appId = "app:\(parentPath.path.hashValue)"

        let appNode = GraphNode(
            id: appId,
            type: .parentApp,
            label: parentPath.deletingPathExtension().lastPathComponent,
            details: nil,
            path: parentPath.path,
            riskScore: nil,
            persistenceItemId: nil
        )
        graph.addNode(appNode)

        graph.addEdge(GraphEdge(
            from: childNode.id,
            to: appId,
            relationship: .belongsTo,
            details: "Part of application bundle"
        ))
    }
}

// MARK: - Quick Analysis (Lightweight)

extension GraphAnalyzer {
    /// Quick analysis without network/dylib deep inspection
    @MainActor
    func quickAnalyze(items: [PersistenceItem]) -> PersistenceGraph {
        graph.clear()

        for item in items {
            let itemNode = createNode(for: item)
            graph.addNode(itemNode)

            // Just link to executable
            if let execPath = item.effectiveExecutablePath {
                let execId = "binary:\(execPath.path.hashValue)"
                let binaryNode = GraphNode(
                    id: execId,
                    type: .binary,
                    label: execPath.lastPathComponent,
                    details: nil,
                    path: execPath.path,
                    riskScore: nil,
                    persistenceItemId: nil
                )
                graph.addNode(binaryNode)
                graph.addEdge(GraphEdge(
                    from: itemNode.id,
                    to: execId,
                    relationship: .executes
                ))
            }

            // Link to parent app
            if let parentPath = item.parentAppPath {
                analyzeParentApp(parentPath, childNode: itemNode)
            }
        }

        return graph
    }
}
