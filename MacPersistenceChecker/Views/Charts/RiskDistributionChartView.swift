import SwiftUI
import Charts

/// Risk level band for categorization
enum RiskBand: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"

    var id: String { rawValue }

    var range: ClosedRange<Int> {
        switch self {
        case .low: return 0...25
        case .medium: return 26...50
        case .high: return 51...75
        case .critical: return 76...100
        }
    }

    var color: Color {
        switch self {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return .red
        }
    }

    var symbolName: String {
        switch self {
        case .low: return "checkmark.circle.fill"
        case .medium: return "exclamationmark.circle.fill"
        case .high: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    static func band(for score: Int) -> RiskBand {
        switch score {
        case 0...25: return .low
        case 26...50: return .medium
        case 51...75: return .high
        default: return .critical
        }
    }
}

/// Data model for risk distribution
struct RiskBandData: Identifiable {
    let id = UUID()
    let band: RiskBand
    let count: Int
}

/// Bar chart showing distribution of items by risk score bands
struct RiskDistributionChartView: View {
    let items: [PersistenceItem]
    var compact: Bool = false

    private var chartData: [RiskBandData] {
        let grouped = Dictionary(grouping: items) { item -> RiskBand in
            RiskBand.band(for: item.riskScore ?? 0)
        }

        return RiskBand.allCases.map { band in
            RiskBandData(band: band, count: grouped[band]?.count ?? 0)
        }
    }

    private var maxCount: Int {
        chartData.map(\.count).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if !compact {
                Label("Risk Distribution", systemImage: "chart.bar.fill")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            if !items.isEmpty {
                Chart(chartData) { data in
                    BarMark(
                        x: .value("Risk Level", data.band.rawValue),
                        y: .value("Count", data.count)
                    )
                    .foregroundStyle(data.band.color.gradient)
                    .cornerRadius(4)
                    .annotation(position: .top) {
                        if data.count > 0 {
                            Text("\(data.count)")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .frame(height: compact ? 80 : 120)

                // Legend with ranges
                if !compact {
                    HStack(spacing: 12) {
                        ForEach(RiskBand.allCases) { band in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(band.color)
                                    .frame(width: 6, height: 6)
                                Text("\(band.range.lowerBound)-\(band.range.upperBound)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } else {
                EmptyChartPlaceholder(message: "No risk data")
            }
        }
        .padding(compact ? 8 : 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }
}

/// Compact risk gauge for individual items
struct RiskGaugeView: View {
    let score: Int

    private var band: RiskBand {
        RiskBand.band(for: score)
    }

    var body: some View {
        Gauge(value: Double(score), in: 0...100) {
            Text("Risk")
        } currentValueLabel: {
            Text("\(score)")
                .font(.caption)
                .fontWeight(.bold)
        } minimumValueLabel: {
            Text("0")
                .font(.caption2)
        } maximumValueLabel: {
            Text("100")
                .font(.caption2)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(band.color)
        .scaleEffect(0.8)
    }
}

#Preview {
    RiskDistributionChartView(items: [])
        .frame(width: 250)
        .padding()
}
