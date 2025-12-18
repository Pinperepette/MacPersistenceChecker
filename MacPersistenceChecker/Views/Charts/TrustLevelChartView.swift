import SwiftUI
import Charts

/// Data model for trust level distribution chart
struct TrustLevelData: Identifiable {
    let id = UUID()
    let trustLevel: TrustLevel
    let count: Int

    var percentage: Double {
        return Double(count)
    }
}

/// Wrapper view that shows appropriate chart based on OS version
struct TrustLevelChartView: View {
    let items: [PersistenceItem]
    var showLegend: Bool = true
    var compact: Bool = false

    var body: some View {
        if #available(macOS 14.0, *) {
            TrustLevelDonutChart(items: items, showLegend: showLegend, compact: compact)
        } else {
            TrustLevelBarChart(items: items, showLegend: showLegend, compact: compact)
        }
    }
}

/// Donut chart showing distribution of items by trust level (macOS 14+)
@available(macOS 14.0, *)
struct TrustLevelDonutChart: View {
    let items: [PersistenceItem]
    var showLegend: Bool = true
    var compact: Bool = false

    private var chartData: [TrustLevelData] {
        let grouped = Dictionary(grouping: items) { $0.trustLevel }
        return TrustLevel.allCases
            .map { level in
                TrustLevelData(trustLevel: level, count: grouped[level]?.count ?? 0)
            }
            .filter { $0.count > 0 }
    }

    private var totalItems: Int {
        items.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if !compact {
                Label("Trust Distribution", systemImage: "chart.pie.fill")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            if totalItems > 0 {
                GeometryReader { geometry in
                    let size = min(geometry.size.width, geometry.size.height)

                    ZStack {
                        // Donut chart
                        Chart(chartData) { data in
                            SectorMark(
                                angle: .value("Count", data.count),
                                innerRadius: .ratio(0.6),
                                angularInset: 1.5
                            )
                            .foregroundStyle(data.trustLevel.color)
                            .cornerRadius(4)
                        }
                        .frame(width: size, height: size)

                        // Center label
                        VStack(spacing: 2) {
                            Text("\(totalItems)")
                                .font(compact ? .title3 : .title2)
                                .fontWeight(.bold)
                            Text("Items")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: compact ? 100 : 140)

                // Legend
                if showLegend {
                    LegendView(data: chartData, compact: compact)
                }
            } else {
                EmptyChartPlaceholder(message: "No items to display")
            }
        }
        .padding(compact ? 8 : 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }
}

/// Bar chart fallback for macOS 13
struct TrustLevelBarChart: View {
    let items: [PersistenceItem]
    var showLegend: Bool = true
    var compact: Bool = false

    private var chartData: [TrustLevelData] {
        let grouped = Dictionary(grouping: items) { $0.trustLevel }
        return TrustLevel.allCases
            .map { level in
                TrustLevelData(trustLevel: level, count: grouped[level]?.count ?? 0)
            }
            .filter { $0.count > 0 }
    }

    private var totalItems: Int {
        items.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if !compact {
                Label("Trust Distribution", systemImage: "chart.bar.fill")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            if totalItems > 0 {
                Chart(chartData) { data in
                    BarMark(
                        x: .value("Trust Level", data.trustLevel.displayName),
                        y: .value("Count", data.count)
                    )
                    .foregroundStyle(data.trustLevel.color.gradient)
                    .cornerRadius(4)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .frame(height: compact ? 100 : 140)

                // Legend
                if showLegend {
                    LegendView(data: chartData, compact: compact)
                }
            } else {
                EmptyChartPlaceholder(message: "No items to display")
            }
        }
        .padding(compact ? 8 : 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }
}

/// Legend for the trust level chart
struct LegendView: View {
    let data: [TrustLevelData]
    var compact: Bool = false

    private var columns: [GridItem] {
        if compact {
            return [GridItem(.flexible()), GridItem(.flexible())]
        } else {
            return [GridItem(.flexible())]
        }
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: compact ? 4 : 6) {
            ForEach(data) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.trustLevel.color)
                        .frame(width: 8, height: 8)

                    Text(item.trustLevel.displayName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text("\(item.count)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
            }
        }
    }
}

/// Placeholder for empty charts
struct EmptyChartPlaceholder: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.pie")
                .font(.largeTitle)
                .foregroundColor(.secondary.opacity(0.5))
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
    }
}

#Preview {
    TrustLevelChartView(items: [])
        .frame(width: 220)
        .padding()
}
