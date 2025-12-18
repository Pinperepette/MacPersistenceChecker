import SwiftUI
import Charts

// MARK: - Mini Security Chart for Node Detail Panel

struct NodeSecurityChartView: View {
    let item: PersistenceItem

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                // Left: Mini Radar
                MiniRadarChartView(item: item)
                    .frame(width: 120, height: 120)

                // Right: Risk breakdown bars
                MiniRiskBreakdownView(item: item)
                    .frame(maxWidth: .infinity)
            }

            // Bottom: Mini timeline
            MiniTimelineView(item: item)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .cornerRadius(10)
    }
}

// MARK: - Mini Radar Chart

struct MiniRadarChartView: View {
    let item: PersistenceItem

    private var dimensions: [(String, Double, Color)] {
        [
            ("Trust", trustScore, .green),
            ("Sign", signatureScore, .blue),
            ("Safe", safetyScore, .purple),
            ("Trans", transparencyScore, .cyan)
        ]
    }

    private var trustScore: Double {
        switch item.trustLevel {
        case .apple: return 100
        case .knownVendor: return 85
        case .signed: return 70
        case .unknown: return 40
        case .suspicious: return 20
        case .unsigned: return 5
        }
    }

    private var signatureScore: Double {
        guard let sig = item.signatureInfo else { return 0 }
        var score: Double = 0
        if sig.isSigned { score += 30 }
        if sig.isValid { score += 25 }
        if sig.isNotarized { score += 25 }
        if sig.hasHardenedRuntime { score += 20 }
        return score
    }

    private var safetyScore: Double {
        100 - Double(item.riskScore ?? 0)
    }

    private var transparencyScore: Double {
        var score: Double = 0
        if item.signatureInfo != nil { score += 25 }
        if item.signatureInfo?.organizationName != nil { score += 25 }
        if item.plistPath != nil { score += 25 }
        if item.executablePath != nil { score += 25 }
        return score
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: size / 2, y: size / 2)
            let radius = size / 2 - 20

            ZStack {
                // Background grid
                ForEach([0.33, 0.66, 1.0], id: \.self) { scale in
                    MiniRadarGrid(center: center, radius: radius * scale, sides: 4)
                }

                // Data polygon
                MiniRadarPolygon(
                    center: center,
                    radius: radius,
                    values: dimensions.map { $0.1 / 100 }
                )

                // Labels
                ForEach(0..<4, id: \.self) { i in
                    let angle = angleFor(index: i, total: 4)
                    let labelRadius = radius + 12
                    let pos = CGPoint(
                        x: center.x + labelRadius * CGFloat(cos(angle)),
                        y: center.y + labelRadius * CGFloat(sin(angle))
                    )

                    VStack(spacing: 0) {
                        Text(dimensions[i].0)
                            .font(.system(size: 7, weight: .medium))
                        Text("\(Int(dimensions[i].1))")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(dimensions[i].2)
                    }
                    .position(pos)
                }
            }
        }
    }

    private func angleFor(index: Int, total: Int) -> Double {
        let base = -Double.pi / 2
        return base + (2 * Double.pi * Double(index)) / Double(total)
    }
}

struct MiniRadarGrid: View {
    let center: CGPoint
    let radius: CGFloat
    let sides: Int

    var body: some View {
        Path { path in
            for i in 0..<sides {
                let angle = -Double.pi / 2 + (2 * Double.pi * Double(i)) / Double(sides)
                let point = CGPoint(
                    x: center.x + radius * CGFloat(cos(angle)),
                    y: center.y + radius * CGFloat(sin(angle))
                )
                if i == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()
        }
        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
    }
}

struct MiniRadarPolygon: View {
    let center: CGPoint
    let radius: CGFloat
    let values: [Double]

    var body: some View {
        ZStack {
            // Fill
            Path { path in
                for (i, value) in values.enumerated() {
                    let angle = -Double.pi / 2 + (2 * Double.pi * Double(i)) / Double(values.count)
                    let r = radius * CGFloat(value)
                    let point = CGPoint(
                        x: center.x + r * CGFloat(cos(angle)),
                        y: center.y + r * CGFloat(sin(angle))
                    )
                    if i == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                path.closeSubpath()
            }
            .fill(Color.accentColor.opacity(0.3))

            // Stroke
            Path { path in
                for (i, value) in values.enumerated() {
                    let angle = -Double.pi / 2 + (2 * Double.pi * Double(i)) / Double(values.count)
                    let r = radius * CGFloat(value)
                    let point = CGPoint(
                        x: center.x + r * CGFloat(cos(angle)),
                        y: center.y + r * CGFloat(sin(angle))
                    )
                    if i == 0 {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                path.closeSubpath()
            }
            .stroke(Color.accentColor, lineWidth: 2)

            // Points
            ForEach(0..<values.count, id: \.self) { i in
                let angle = -Double.pi / 2 + (2 * Double.pi * Double(i)) / Double(values.count)
                let r = radius * CGFloat(values[i])
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .position(
                        x: center.x + r * CGFloat(cos(angle)),
                        y: center.y + r * CGFloat(sin(angle))
                    )
            }
        }
    }
}

// MARK: - Mini Risk Breakdown

struct MiniRiskBreakdownView: View {
    let item: PersistenceItem

    private var riskFactors: [(String, Int, Color)] {
        guard let details = item.riskDetails else { return [] }
        return details.prefix(4).map { detail in
            let color: Color = detail.points >= 20 ? .red : (detail.points >= 10 ? .orange : .yellow)
            return (String(detail.factor.prefix(10)), detail.points, color)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header with total score
            HStack {
                Text("Risk Score")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                RiskScoreGauge(score: item.riskScore ?? 0)
            }

            if !riskFactors.isEmpty {
                // Risk factors as mini bars
                ForEach(Array(riskFactors.enumerated()), id: \.offset) { _, factor in
                    HStack(spacing: 6) {
                        Text(factor.0)
                            .font(.system(size: 8))
                            .frame(width: 50, alignment: .leading)
                            .lineLimit(1)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.secondary.opacity(0.2))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(factor.2.gradient)
                                    .frame(width: geo.size.width * CGFloat(factor.1) / 40)
                            }
                        }
                        .frame(height: 6)

                        Text("+\(factor.1)")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(factor.2)
                            .frame(width: 20)
                    }
                }
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("No risk factors")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct RiskScoreGauge: View {
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
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: 3)
                .frame(width: 32, height: 32)

            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 32, height: 32)
                .rotationEffect(.degrees(-90))

            Text("\(score)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(color)
        }
    }
}

// MARK: - Mini Timeline

struct MiniTimelineView: View {
    let item: PersistenceItem

    private var events: [(String, Date, Color)] {
        var result: [(String, Date, Color)] = []

        if let date = item.plistCreatedAt {
            result.append(("Created", date, .green))
        }
        if let date = item.plistModifiedAt {
            result.append(("Modified", date, .orange))
        }
        if let date = item.binaryLastExecutedAt {
            result.append(("Executed", date, .blue))
        }
        result.append(("Discovered", item.discoveredAt, .purple))

        return result.sorted { $0.1 < $1.1 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timeline")
                .font(.caption2)
                .foregroundColor(.secondary)

            GeometryReader { geo in
                let width = geo.size.width

                ZStack(alignment: .leading) {
                    // Line
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 2)
                        .offset(y: 6)

                    // Events
                    HStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                            VStack(spacing: 2) {
                                Circle()
                                    .fill(event.2)
                                    .frame(width: 12, height: 12)

                                Text(event.0)
                                    .font(.system(size: 6))
                                    .foregroundColor(.secondary)

                                Text(relativeDate(event.1))
                                    .font(.system(size: 5))
                                    .foregroundColor(.secondary.opacity(0.8))
                            }
                            .frame(width: width / CGFloat(events.count))
                        }
                    }
                }
            }
            .frame(height: 36)
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Graph Stats Chart (for top panel)

struct GraphStatsChartView: View {
    let stats: GraphStatistics
    let nodes: [GraphNode]

    private var nodeTypeData: [(String, Int, Color)] {
        var counts: [GraphNode.NodeType: Int] = [:]
        for node in nodes {
            counts[node.type, default: 0] += 1
        }
        return counts.map { ($0.key.rawValue, $0.value, $0.key.color) }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        HStack(spacing: 16) {
            // Node type distribution - Mini donut
            if #available(macOS 14.0, *) {
                MiniDonutChart(data: nodeTypeData)
                    .frame(width: 60, height: 60)
            }

            // Stats numbers
            VStack(alignment: .leading, spacing: 4) {
                StatRow(icon: "circle.fill", label: "Nodes", value: stats.totalNodes, color: .blue)
                StatRow(icon: "arrow.right", label: "Edges", value: stats.totalEdges, color: .green)
            }

            VStack(alignment: .leading, spacing: 4) {
                if stats.networkConnections > 0 {
                    StatRow(icon: "network", label: "Network", value: stats.networkConnections, color: .red)
                }
                if stats.dylibCount > 0 {
                    StatRow(icon: "shippingbox", label: "Dylibs", value: stats.dylibCount, color: .orange)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }
}

@available(macOS 14.0, *)
struct MiniDonutChart: View {
    let data: [(String, Int, Color)]

    var body: some View {
        Chart(data, id: \.0) { item in
            SectorMark(
                angle: .value("Count", item.1),
                innerRadius: .ratio(0.5),
                angularInset: 1
            )
            .foregroundStyle(item.2)
        }
    }
}

struct StatRow: View {
    let icon: String
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(color)
            Text("\(value)")
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Text("Node Chart Preview")
    }
    .frame(width: 400, height: 200)
    .padding()
}
