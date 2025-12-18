import SwiftUI
import Charts

// MARK: - Security Profile Chart (Complex Combined View)

/// A comprehensive security profile visualization for a persistence item
struct SecurityProfileChartView: View {
    let item: PersistenceItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Label("Security Profile", systemImage: "shield.checkered")
                .font(.headline)

            // Main content in a grid
            HStack(alignment: .top, spacing: 20) {
                // Left: Radar Chart
                VStack {
                    SecurityRadarChart(item: item)
                    Text("Security Dimensions")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)

                // Right: Risk Factors Bar Chart
                VStack {
                    RiskFactorsBarChart(item: item)
                    Text("Risk Contribution")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }

            // Bottom: Timeline
            TimelineChart(item: item)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }
}

// MARK: - Security Radar Chart

struct SecurityRadarChart: View {
    let item: PersistenceItem

    // Security dimensions (0-100 scale, higher = better/safer)
    private var dimensions: [SecurityDimension] {
        [
            SecurityDimension(
                name: "Trust",
                value: trustScore,
                color: .green
            ),
            SecurityDimension(
                name: "Signature",
                value: signatureScore,
                color: .blue
            ),
            SecurityDimension(
                name: "Safety",
                value: safetyScore,
                color: .purple
            ),
            SecurityDimension(
                name: "Stability",
                value: stabilityScore,
                color: .orange
            ),
            SecurityDimension(
                name: "Transparency",
                value: transparencyScore,
                color: .cyan
            ),
            SecurityDimension(
                name: "Age",
                value: ageScore,
                color: .pink
            )
        ]
    }

    // Trust score based on trust level
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

    // Signature score based on signature info
    private var signatureScore: Double {
        guard let sig = item.signatureInfo else { return 0 }
        var score: Double = 0
        if sig.isSigned { score += 30 }
        if sig.isValid { score += 25 }
        if sig.isNotarized { score += 25 }
        if sig.hasHardenedRuntime { score += 20 }
        return score
    }

    // Safety score (inverse of risk score)
    private var safetyScore: Double {
        100 - Double(item.riskScore ?? 0)
    }

    // Stability score based on whether executable exists and is enabled
    private var stabilityScore: Double {
        var score: Double = 50
        if item.isEnabled { score += 25 }
        if item.isLoaded { score += 25 }
        if let path = item.executablePath {
            if FileManager.default.fileExists(atPath: path.path) {
                score = min(100, score)
            } else {
                score -= 30
            }
        }
        return max(0, min(100, score))
    }

    // Transparency score based on available information
    private var transparencyScore: Double {
        var score: Double = 0
        if item.signatureInfo != nil { score += 20 }
        if item.signatureInfo?.organizationName != nil { score += 20 }
        if item.plistPath != nil { score += 20 }
        if item.executablePath != nil { score += 20 }
        if item.plistCreatedAt != nil || item.binaryCreatedAt != nil { score += 20 }
        return score
    }

    // Age score - older items are generally more trusted
    private var ageScore: Double {
        guard let created = item.plistCreatedAt ?? item.binaryCreatedAt else { return 50 }
        let daysOld = Date().timeIntervalSince(created) / 86400
        if daysOld > 365 { return 100 }
        if daysOld > 180 { return 80 }
        if daysOld > 30 { return 60 }
        if daysOld > 7 { return 40 }
        return 20 // Very new items are suspicious
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = size / 2 - 30

            ZStack {
                // Background circles
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { scale in
                    RadarGridCircle(
                        center: center,
                        radius: radius * scale,
                        sides: dimensions.count
                    )
                }

                // Axis lines
                ForEach(0..<dimensions.count, id: \.self) { index in
                    RadarAxisLine(
                        center: center,
                        radius: radius,
                        index: index,
                        total: dimensions.count
                    )
                }

                // Data polygon
                RadarDataPolygon(
                    center: center,
                    radius: radius,
                    dimensions: dimensions
                )

                // Labels
                ForEach(0..<dimensions.count, id: \.self) { index in
                    RadarLabel(
                        dimension: dimensions[index],
                        center: center,
                        radius: radius + 20,
                        index: index,
                        total: dimensions.count
                    )
                }
            }
        }
        .frame(height: 180)
    }
}

struct SecurityDimension: Identifiable {
    let id = UUID()
    let name: String
    let value: Double // 0-100
    let color: Color
}

struct RadarGridCircle: View {
    let center: CGPoint
    let radius: CGFloat
    let sides: Int

    var body: some View {
        Path { path in
            let points = polygonPoints(center: center, radius: radius, sides: sides)
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
    }
}

struct RadarAxisLine: View {
    let center: CGPoint
    let radius: CGFloat
    let index: Int
    let total: Int

    var body: some View {
        Path { path in
            let angle = angleForIndex(index, total: total)
            let endPoint = pointOnCircle(center: center, radius: radius, angle: angle)
            path.move(to: center)
            path.addLine(to: endPoint)
        }
        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
    }
}

struct RadarDataPolygon: View {
    let center: CGPoint
    let radius: CGFloat
    let dimensions: [SecurityDimension]

    var body: some View {
        ZStack {
            // Fill
            Path { path in
                let points = dataPoints()
                guard !points.isEmpty else { return }
                path.move(to: points[0])
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Stroke
            Path { path in
                let points = dataPoints()
                guard !points.isEmpty else { return }
                path.move(to: points[0])
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                path.closeSubpath()
            }
            .stroke(Color.accentColor, lineWidth: 2)

            // Data points
            ForEach(0..<dimensions.count, id: \.self) { index in
                let point = dataPoint(for: index)
                Circle()
                    .fill(dimensions[index].color)
                    .frame(width: 8, height: 8)
                    .position(point)
            }
        }
    }

    private func dataPoints() -> [CGPoint] {
        (0..<dimensions.count).map { dataPoint(for: $0) }
    }

    private func dataPoint(for index: Int) -> CGPoint {
        let angle = angleForIndex(index, total: dimensions.count)
        let value = dimensions[index].value / 100
        let r = radius * CGFloat(value)
        return pointOnCircle(center: center, radius: r, angle: angle)
    }
}

struct RadarLabel: View {
    let dimension: SecurityDimension
    let center: CGPoint
    let radius: CGFloat
    let index: Int
    let total: Int

    var body: some View {
        let angle = angleForIndex(index, total: total)
        let point = pointOnCircle(center: center, radius: radius, angle: angle)

        VStack(spacing: 0) {
            Text(dimension.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
            Text("\(Int(dimension.value))")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(dimension.color)
        }
        .position(point)
    }
}

// MARK: - Risk Factors Bar Chart

struct RiskFactorsBarChart: View {
    let item: PersistenceItem

    private var riskFactors: [RiskFactorData] {
        guard let details = item.riskDetails else { return [] }
        return details.prefix(5).map { detail in
            RiskFactorData(
                name: String(detail.factor.prefix(12)),
                points: detail.points,
                color: colorForPoints(detail.points)
            )
        }
    }

    private func colorForPoints(_ points: Int) -> Color {
        switch points {
        case 0..<10: return .yellow
        case 10..<20: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !riskFactors.isEmpty {
                Chart(riskFactors) { factor in
                    BarMark(
                        x: .value("Points", factor.points),
                        y: .value("Factor", factor.name)
                    )
                    .foregroundStyle(factor.color.gradient)
                    .cornerRadius(4)
                    .annotation(position: .trailing) {
                        Text("+\(factor.points)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(factor.color)
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom) { _ in
                        AxisGridLine()
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
            } else {
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.green)
                    Text("No Risk Factors")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 150)
    }
}

struct RiskFactorData: Identifiable {
    let id = UUID()
    let name: String
    let points: Int
    let color: Color
}

// MARK: - Timeline Chart

struct TimelineChart: View {
    let item: PersistenceItem

    private var timelineEvents: [TimelineEvent] {
        var events: [TimelineEvent] = []

        if let date = item.plistCreatedAt {
            events.append(TimelineEvent(date: date, label: "Created", color: .green, icon: "plus.circle.fill"))
        }
        if let date = item.plistModifiedAt {
            events.append(TimelineEvent(date: date, label: "Modified", color: .orange, icon: "pencil.circle.fill"))
        }
        if let date = item.binaryLastExecutedAt {
            events.append(TimelineEvent(date: date, label: "Executed", color: .blue, icon: "play.circle.fill"))
        }
        // discoveredAt is not optional, always add it
        let discoveredDate = item.discoveredAt
        events.append(TimelineEvent(date: discoveredDate, label: "Discovered", color: .purple, icon: "eye.circle.fill"))

        return events.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Event Timeline")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            if !timelineEvents.isEmpty {
                GeometryReader { geometry in
                    let width = geometry.size.width

                    ZStack(alignment: .leading) {
                        // Timeline line
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(height: 2)
                            .offset(y: 15)

                        // Events
                        HStack(spacing: 0) {
                            ForEach(Array(timelineEvents.enumerated()), id: \.element.id) { index, event in
                                TimelineEventView(event: event)
                                    .frame(width: width / CGFloat(timelineEvents.count))
                            }
                        }
                    }
                }
                .frame(height: 60)
            } else {
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                    Text("No timeline data available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
            }
        }
    }
}

struct TimelineEvent: Identifiable {
    let id = UUID()
    let date: Date
    let label: String
    let color: Color
    let icon: String
}

struct TimelineEventView: View {
    let event: TimelineEvent

    private var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: event.date, relativeTo: Date())
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: event.icon)
                .font(.title3)
                .foregroundColor(event.color)

            Text(event.label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.primary)

            Text(relativeDate)
                .font(.system(size: 7))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Helper Functions

private func angleForIndex(_ index: Int, total: Int) -> Double {
    let baseAngle = -Double.pi / 2 // Start from top
    let anglePerSide = 2 * Double.pi / Double(total)
    return baseAngle + anglePerSide * Double(index)
}

private func pointOnCircle(center: CGPoint, radius: CGFloat, angle: Double) -> CGPoint {
    CGPoint(
        x: center.x + radius * CGFloat(cos(angle)),
        y: center.y + radius * CGFloat(sin(angle))
    )
}

private func polygonPoints(center: CGPoint, radius: CGFloat, sides: Int) -> [CGPoint] {
    (0..<sides).map { index in
        let angle = angleForIndex(index, total: sides)
        return pointOnCircle(center: center, radius: radius, angle: angle)
    }
}

// MARK: - Preview

#Preview {
    // Preview with empty state
    VStack {
        Text("Security Profile Chart Preview")
            .font(.headline)
        Text("Select an item in the app to see the chart")
            .foregroundColor(.secondary)
    }
    .frame(width: 500, height: 400)
    .padding()
}
