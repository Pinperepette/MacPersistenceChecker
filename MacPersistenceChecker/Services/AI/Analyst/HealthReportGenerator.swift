import Foundation

/// Builds a human-readable health report on the Mac's persistence posture.
/// One Sonnet call per request — costlier than item-level analysis but
/// produces narrative output worth reading.
@MainActor
final class HealthReportGenerator {
    static let shared = HealthReportGenerator()

    private let configuration = AIConfiguration.shared
    private let apiClient = ClaudeAPIClient()

    private init() {}

    enum ReportError: Error, LocalizedError {
        case aiNotAvailable
        case dailyCapReached
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .aiNotAvailable: return "AI is disabled or the API key is missing."
            case .dailyCapReached: return "Daily AI call cap reached."
            case .underlying(let err): return err.localizedDescription
            }
        }
    }

    struct Report {
        let markdown: String
        let generatedAt: Date
        let inputItemCount: Int
    }

    // MARK: - Public

    /// Generates a health report from the current items + graph state. Uses
    /// the Sonnet model. Costs ~$0.05-0.10 per call (input is large because
    /// we include cluster summaries and residuals).
    func generate(items: [PersistenceItem]) async throws -> Report {
        guard configuration.isAIActive else { throw ReportError.aiNotAvailable }
        guard configuration.canMakeCall else { throw ReportError.dailyCapReached }

        // Compute the input payload off-main: cluster stats, vendor mix,
        // residual suspicious items.
        let payloadJSON: String = await Task.detached(priority: .userInitiated) {
            let clusters = ClusterBuilder.shared.buildClusters(from: items)
            let payload = HealthReportGenerator.buildPayload(items: items, clusters: clusters)
            if let data = try? JSONEncoder().encode(payload),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "{}"
        }.value

        let systemPrompt = PromptLoader.load(.healthReport)
        let model = configuration.sonnetModel

        do {
            let raw = try await apiClient.chatRaw(
                systemPrompt: systemPrompt,
                userJSON: payloadJSON,
                model: model,
                maxTokens: 2000
            )
            configuration.recordCall()
            // Sonnet returns markdown directly per prompt — no JSON parse needed.
            return Report(
                markdown: raw,
                generatedAt: Date(),
                inputItemCount: items.count
            )
        } catch {
            // Even on failure, count the API call (we hit the network).
            configuration.recordCall()
            throw ReportError.underlying(error)
        }
    }

    // MARK: - Payload

    /// Aggregates the data Sonnet needs: top clusters, vendor distribution,
    /// non-Apple residuals. Designed to fit comfortably in one prompt.
    /// `nonisolated` because it's called from a Task.detached.
    private nonisolated static func buildPayload(
        items: [PersistenceItem],
        clusters: [ConceptCluster]
    ) -> ReportPayload {
        // Vendor distribution.
        var appleSigned = 0
        var teamIDSigned = 0
        var unsigned = 0
        var other = 0
        var teamIDs: [String: Int] = [:]
        for item in items {
            if item.signatureInfo?.isAppleSigned == true {
                appleSigned += 1
            } else if let team = item.signatureInfo?.teamIdentifier, !team.isEmpty {
                teamIDSigned += 1
                teamIDs[team, default: 0] += 1
            } else if item.trustLevel == .unsigned {
                unsigned += 1
            } else {
                other += 1
            }
        }

        // Top clusters by member count.
        let topClusters = clusters
            .sorted { $0.memberItems.count > $1.memberItems.count }
            .prefix(15)
            .map { cluster -> ClusterSummary in
                ClusterSummary(
                    label: cluster.displayLabel,
                    memberCount: cluster.memberItems.count,
                    conceptIDs: cluster.conceptIDs,
                    verdict: cluster.currentVerdict?.rawValue ?? "unclassified",
                    sampleNames: cluster.sampleItems.prefix(3).map(\.name)
                )
            }

        // Residual suspicious items: high-risk + non-graph-classified.
        let residuals = items
            .filter { item in
                let fingerprint = ItemFingerprint.make(from: item).hash
                let conceptIDs = ConceptIngestor.shared.conceptIDs(forFingerprint: fingerprint)
                let resolved = ConceptResolver.shared.resolve(item: item, linkedConceptIDs: conceptIDs)
                if case .classified(let verdict, _) = resolved.outcome, verdict == .benign {
                    return false
                }
                if case .knownBenign(_, let conf) = RuleMatcher.shared.evaluate(item: item), conf >= 0.7 {
                    return false
                }
                return (item.riskScore ?? 0) >= 30
            }
            .sorted { ($0.riskScore ?? 0) > ($1.riskScore ?? 0) }
            .prefix(15)
            .map { item -> ResidualItem in
                ResidualItem(
                    name: item.name,
                    identifier: item.identifier,
                    category: item.category.rawValue,
                    riskScore: item.riskScore ?? 0,
                    trustLevel: item.trustLevel.rawValue,
                    teamID: item.signatureInfo?.teamIdentifier,
                    organization: item.signatureInfo?.organizationName,
                    executablePath: item.executablePath?.path,
                    plistPath: item.plistPath?.path
                )
            }

        return ReportPayload(
            totalItems: items.count,
            vendorDistribution: VendorDistribution(
                appleSigned: appleSigned,
                teamIDSigned: teamIDSigned,
                unsigned: unsigned,
                other: other,
                topTeamIDs: teamIDs
                    .sorted { $0.value > $1.value }
                    .prefix(10)
                    .map { TeamIDSummary(teamID: $0.key, count: $0.value) }
            ),
            clusterCount: clusters.count,
            topClusters: Array(topClusters),
            residualSuspicious: Array(residuals),
            systemInfo: SystemInfo(
                hostname: Host.current().localizedName ?? "Unknown",
                macosVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
        )
    }

    // MARK: - Payload types

    private struct ReportPayload: Codable {
        let totalItems: Int
        let vendorDistribution: VendorDistribution
        let clusterCount: Int
        let topClusters: [ClusterSummary]
        let residualSuspicious: [ResidualItem]
        let systemInfo: SystemInfo
    }

    private struct VendorDistribution: Codable {
        let appleSigned: Int
        let teamIDSigned: Int
        let unsigned: Int
        let other: Int
        let topTeamIDs: [TeamIDSummary]
    }

    private struct TeamIDSummary: Codable {
        let teamID: String
        let count: Int
    }

    private struct ClusterSummary: Codable {
        let label: String
        let memberCount: Int
        let conceptIDs: [String]
        let verdict: String
        let sampleNames: [String]
    }

    private struct ResidualItem: Codable {
        let name: String
        let identifier: String
        let category: String
        let riskScore: Int
        let trustLevel: String
        let teamID: String?
        let organization: String?
        let executablePath: String?
        let plistPath: String?
    }

    private struct SystemInfo: Codable {
        let hostname: String
        let macosVersion: String
    }
}
