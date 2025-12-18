import SwiftUI
import Charts

/// Data model for category breakdown
struct CategoryData: Identifiable {
    let id = UUID()
    let category: PersistenceCategory
    let count: Int
    let isExtended: Bool
}

/// Horizontal bar chart showing items per category
struct CategoryBreakdownChartView: View {
    let items: [PersistenceItem]
    var showExtended: Bool = true
    var compact: Bool = false
    var maxCategories: Int = 8

    private var chartData: [CategoryData] {
        let grouped = Dictionary(grouping: items) { $0.category }

        var data = PersistenceCategory.allCases
            .filter { category in
                if !showExtended && PersistenceCategory.extendedCategories.contains(category) {
                    return false
                }
                return (grouped[category]?.count ?? 0) > 0
            }
            .map { category in
                CategoryData(
                    category: category,
                    count: grouped[category]?.count ?? 0,
                    isExtended: PersistenceCategory.extendedCategories.contains(category)
                )
            }
            .sorted { $0.count > $1.count }

        // Limit to top categories
        if data.count > maxCategories {
            data = Array(data.prefix(maxCategories))
        }

        return data
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if !compact {
                Label("Categories", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            if !chartData.isEmpty {
                Chart(chartData) { data in
                    BarMark(
                        x: .value("Count", data.count),
                        y: .value("Category", data.category.displayName)
                    )
                    .foregroundStyle(
                        data.isExtended
                            ? Color.purple.gradient
                            : Color.accentColor.gradient
                    )
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("\(data.count)")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .frame(height: CGFloat(chartData.count) * (compact ? 24 : 28) + 20)

                // Legend for extended vs core
                if showExtended && chartData.contains(where: { $0.isExtended }) {
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.accentColor)
                                .frame(width: 12, height: 8)
                            Text("Core")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.purple)
                                .frame(width: 12, height: 8)
                            Text("Extended")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                EmptyChartPlaceholder(message: "No categories to display")
            }
        }
        .padding(compact ? 8 : 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }
}

/// Mini sparkline for category trend (placeholder for future snapshot comparison)
struct CategorySparklineView: View {
    let values: [Int]
    let color: Color

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                LineMark(
                    x: .value("Index", index),
                    y: .value("Value", value)
                )
                .foregroundStyle(color)
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Index", index),
                    y: .value("Value", value)
                )
                .foregroundStyle(color.opacity(0.2).gradient)
                .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

#Preview {
    CategoryBreakdownChartView(items: [])
        .frame(width: 300)
        .padding()
}
