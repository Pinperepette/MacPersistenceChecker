import SwiftUI
import Charts

/// Full statistics dashboard with all charts
struct StatsDashboardView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header with summary
                SummaryHeaderView(items: appState.items)

                // Charts grid
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ], spacing: 16) {
                    // Trust Level Distribution
                    TrustLevelChartView(items: appState.items)

                    // Risk Distribution
                    RiskDistributionChartView(items: appState.items)
                }

                // Full width category breakdown
                CategoryBreakdownChartView(
                    items: appState.items,
                    showExtended: true,
                    maxCategories: 12
                )

                // Signature status breakdown
                SignatureStatusChartView(items: appState.items)
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Statistics Dashboard")
    }
}

/// Summary header with key metrics
struct SummaryHeaderView: View {
    let items: [PersistenceItem]

    private var suspiciousCount: Int {
        items.filter { $0.trustLevel == .suspicious || $0.trustLevel == .unsigned }.count
    }

    private var averageRiskScore: Int {
        guard !items.isEmpty else { return 0 }
        let total = items.compactMap(\.riskScore).reduce(0, +)
        return total / max(items.count, 1)
    }

    private var highRiskCount: Int {
        items.filter { ($0.riskScore ?? 0) > 50 }.count
    }

    var body: some View {
        HStack(spacing: 16) {
            MetricCard(
                title: "Total Items",
                value: "\(items.count)",
                icon: "list.bullet",
                color: .blue
            )

            MetricCard(
                title: "Suspicious",
                value: "\(suspiciousCount)",
                icon: "exclamationmark.triangle.fill",
                color: suspiciousCount > 0 ? .red : .green
            )

            MetricCard(
                title: "Avg Risk",
                value: "\(averageRiskScore)",
                icon: "gauge.medium",
                color: averageRiskScore > 50 ? .orange : .green
            )

            MetricCard(
                title: "High Risk",
                value: "\(highRiskCount)",
                icon: "exclamationmark.octagon.fill",
                color: highRiskCount > 0 ? .orange : .green
            )
        }
    }
}

/// Individual metric card
struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Spacer()
            }

            HStack {
                Text(value)
                    .font(.title)
                    .fontWeight(.bold)
                    .monospacedDigit()
                Spacer()
            }

            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }
}

/// Signature verification status chart
struct SignatureStatusChartView: View {
    let items: [PersistenceItem]

    private struct SignatureData: Identifiable {
        let id = UUID()
        let status: String
        let count: Int
        let color: Color
    }

    private var chartData: [SignatureData] {
        var notarized = 0
        var signedNotNotarized = 0
        var unsigned = 0
        var unknown = 0

        for item in items {
            if let sigInfo = item.signatureInfo {
                if sigInfo.isNotarized {
                    notarized += 1
                } else if item.trustLevel == .apple || item.trustLevel == .knownVendor || item.trustLevel == .signed {
                    signedNotNotarized += 1
                } else if item.trustLevel == .unsigned {
                    unsigned += 1
                } else {
                    unknown += 1
                }
            } else {
                if item.trustLevel == .unsigned {
                    unsigned += 1
                } else {
                    unknown += 1
                }
            }
        }

        return [
            SignatureData(status: "Notarized", count: notarized, color: .green),
            SignatureData(status: "Signed", count: signedNotNotarized, color: .blue),
            SignatureData(status: "Unsigned", count: unsigned, color: .red),
            SignatureData(status: "Unknown", count: unknown, color: .gray)
        ].filter { $0.count > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Signature Status", systemImage: "signature")
                .font(.headline)
                .foregroundColor(.secondary)

            if !chartData.isEmpty {
                Chart(chartData) { data in
                    BarMark(
                        x: .value("Status", data.status),
                        y: .value("Count", data.count)
                    )
                    .foregroundStyle(data.color.gradient)
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
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                            .foregroundStyle(Color.secondary.opacity(0.3))
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .frame(height: 150)
            } else {
                EmptyChartPlaceholder(message: "No signature data")
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
    }
}

/// Compact chart section for sidebar
struct SidebarChartsSection: View {
    let items: [PersistenceItem]

    var body: some View {
        VStack(spacing: 12) {
            TrustLevelChartView(items: items, showLegend: true, compact: true)
            RiskDistributionChartView(items: items, compact: true)
        }
    }
}

#Preview {
    StatsDashboardView()
        .environmentObject(AppState.shared)
        .frame(width: 800, height: 600)
}
