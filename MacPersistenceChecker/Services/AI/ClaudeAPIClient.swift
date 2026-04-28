import Foundation

/// Client for Claude API
@MainActor
final class ClaudeAPIClient {
    private let configuration: AIConfiguration
    private let session: URLSession

    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private let apiVersion = "2023-06-01"

    init(configuration: AIConfiguration = .shared) {
        self.configuration = configuration
        self.session = URLSession.shared
    }

    // MARK: - Request/Response Types

    struct AnalysisRequest: Codable {
        let diffSummary: String
        let addedItems: [ItemSummary]
        let removedItems: [ItemSummary]
        let modifiedItems: [ModifiedItemSummary]
        let currentStats: SystemStats
        let systemInfo: SystemInfo
    }

    struct ItemSummary: Codable {
        let identifier: String
        let name: String
        let category: String
        let trustLevel: String
        let riskScore: Int
        let executablePath: String?
        let isAppleSigned: Bool
        let hasLolbins: Bool
    }

    struct ModifiedItemSummary: Codable {
        let identifier: String
        let name: String
        let changes: [String]
    }

    struct SystemStats: Codable {
        let totalItems: Int
        let unsignedCount: Int
        let criticalRiskCount: Int
        let highRiskCount: Int
        let lolbinItemCount: Int
    }

    struct SystemInfo: Codable {
        let hostname: String
        let macosVersion: String
    }

    struct AnalysisResponse: Codable {
        let severity: String
        let summary: String
        let findings: [Finding]
        let recommendations: [String]
    }

    struct Finding: Codable {
        let severity: String
        let title: String
        let description: String
        let affectedItems: [String]
        let mitreTechniques: [String]?
    }

    // MARK: - Single Item Analysis (for Monitoring)

    /// Detailed analysis request for a single changed item
    struct DetailedItemAnalysis: Codable {
        let changeType: String // "added", "removed", "modified"
        let changes: [String]? // For modified items, what changed

        // Basic info
        let identifier: String
        let name: String
        let category: String
        let isEnabled: Bool
        let isLoaded: Bool

        // Paths
        let plistPath: String?
        let executablePath: String?
        let parentAppPath: String?
        let workingDirectory: String?

        // Plist content
        let programArguments: [String]?
        let runAtLoad: Bool?
        let keepAlive: Bool?
        let environmentVariables: [String: String]?
        let startInterval: Int?
        let startCalendarInterval: [[String: Int]]?

        // Signature info
        let signature: SignatureDetails?

        // Risk assessment
        let riskScore: Int?
        let riskDetails: [String]?
        let trustLevel: String

        // LOLBins
        let lolbinsDetections: [LOLBinDetail]?
        let lolbinsRisk: Int?

        // Behavioral anomalies
        let behavioralAnomalies: [BehavioralDetail]?
        let behavioralRiskPoints: Int?

        // Intent mismatches
        let intentMismatches: [IntentMismatchDetail]?
        let intentMismatchRiskPoints: Int?

        // Age anomalies
        let ageAnomalies: [AgeAnomalyDetail]?
        let ageAnomalyRiskPoints: Int?

        // Signed-but-dangerous flags
        let signedButDangerousFlags: [DangerFlagDetail]?
        let signedButDangerousRisk: String?

        // Timestamps
        let plistCreatedAt: String?
        let plistModifiedAt: String?
        let binaryCreatedAt: String?
        let binaryModifiedAt: String?
        let discoveredAt: String

        // System context
        let systemInfo: SystemInfo

        struct SignatureDetails: Codable {
            let isSigned: Bool
            let isValid: Bool
            let isAppleSigned: Bool
            let isNotarized: Bool
            let hasHardenedRuntime: Bool
            let teamIdentifier: String?
            let organizationName: String?
            let commonName: String?
            let signingAuthority: String?
            let isCertificateExpired: Bool
            let certificateExpirationDate: String?
        }

        struct LOLBinDetail: Codable {
            let binary: String
            let category: String
            let severity: String
            let description: String
            let reason: String
            let mitreTechnique: String?
            let riskPoints: Int
        }

        struct BehavioralDetail: Codable {
            let type: String
            let title: String
            let description: String
            let severity: String
            let riskPoints: Int
            let tags: [String]
        }

        struct IntentMismatchDetail: Codable {
            let type: String
            let title: String
            let description: String
            let severity: String
            let riskPoints: Int
            let plistIntent: String
            let binaryReality: String
        }

        struct AgeAnomalyDetail: Codable {
            let type: String
            let title: String
            let description: String
            let severity: String
            let riskPoints: Int
            let plistAge: String
            let binaryAge: String
            let timeDifference: String
        }

        struct DangerFlagDetail: Codable {
            let type: String
            let title: String
            let description: String
            let points: Int
            let severity: String
        }
    }

    /// Response for single item analysis
    struct SingleItemAnalysisResponse: Codable {
        let shouldNotify: Bool
        let severity: String
        let title: String
        let explanation: String
        let recommendation: String?
        let mitreTechniques: [String]?
    }

    /// Create detailed analysis from a PersistenceItem
    static func createDetailedAnalysis(
        from item: PersistenceItem,
        changeType: String,
        changes: [String]? = nil
    ) -> DetailedItemAnalysis {
        let dateFormatter = ISO8601DateFormatter()

        // Signature details
        var signatureDetails: DetailedItemAnalysis.SignatureDetails? = nil
        if let sig = item.signatureInfo {
            signatureDetails = DetailedItemAnalysis.SignatureDetails(
                isSigned: sig.isSigned,
                isValid: sig.isValid,
                isAppleSigned: sig.isAppleSigned,
                isNotarized: sig.isNotarized,
                hasHardenedRuntime: sig.hasHardenedRuntime,
                teamIdentifier: sig.teamIdentifier,
                organizationName: sig.organizationName,
                commonName: sig.commonName,
                signingAuthority: sig.signingAuthority,
                isCertificateExpired: sig.isCertificateExpired,
                certificateExpirationDate: sig.certificateExpirationDate.map { dateFormatter.string(from: $0) }
            )
        }

        // LOLBins
        let lolbins = item.lolbinsDetections?.map { det in
            DetailedItemAnalysis.LOLBinDetail(
                binary: det.binary,
                category: det.category,
                severity: det.severity,
                description: det.description,
                reason: det.reason,
                mitreTechnique: det.mitreTechnique,
                riskPoints: det.riskPoints
            )
        }

        // Behavioral anomalies
        let behavioral = item.behavioralAnomalies?.map { anom in
            DetailedItemAnalysis.BehavioralDetail(
                type: anom.type,
                title: anom.title,
                description: anom.description,
                severity: anom.severity,
                riskPoints: anom.riskPoints,
                tags: anom.tags
            )
        }

        // Intent mismatches
        let intentMismatches = item.intentMismatches?.map { mis in
            DetailedItemAnalysis.IntentMismatchDetail(
                type: mis.type,
                title: mis.title,
                description: mis.description,
                severity: mis.severity,
                riskPoints: mis.riskPoints,
                plistIntent: mis.plistIntent,
                binaryReality: mis.binaryReality
            )
        }

        // Age anomalies
        let ageAnomalies = item.ageAnomalies?.map { anom in
            DetailedItemAnalysis.AgeAnomalyDetail(
                type: anom.type,
                title: anom.title,
                description: anom.description,
                severity: anom.severity,
                riskPoints: anom.riskPoints,
                plistAge: anom.plistAge,
                binaryAge: anom.binaryAge,
                timeDifference: anom.timeDifference
            )
        }

        // Signed-but-dangerous flags
        let dangerFlags = item.signedButDangerousFlags?.map { flag in
            DetailedItemAnalysis.DangerFlagDetail(
                type: flag.type,
                title: flag.title,
                description: flag.description,
                points: flag.points,
                severity: flag.severity
            )
        }

        // Risk details as strings
        let riskDetails = item.riskDetails?.map { "\($0.factor): \($0.description) (+\($0.points))" }

        return DetailedItemAnalysis(
            changeType: changeType,
            changes: changes,
            identifier: item.identifier,
            name: item.name,
            category: item.category.rawValue,
            isEnabled: item.isEnabled,
            isLoaded: item.isLoaded,
            plistPath: item.plistPath?.path,
            executablePath: item.executablePath?.path,
            parentAppPath: item.parentAppPath?.path,
            workingDirectory: item.workingDirectory,
            programArguments: item.programArguments,
            runAtLoad: item.runAtLoad,
            keepAlive: item.keepAlive,
            environmentVariables: item.environmentVariables,
            startInterval: item.startInterval,
            startCalendarInterval: item.startCalendarInterval,
            signature: signatureDetails,
            riskScore: item.riskScore,
            riskDetails: riskDetails,
            trustLevel: item.trustLevel.rawValue,
            lolbinsDetections: lolbins,
            lolbinsRisk: item.lolbinsRisk,
            behavioralAnomalies: behavioral,
            behavioralRiskPoints: item.behavioralRiskPoints,
            intentMismatches: intentMismatches,
            intentMismatchRiskPoints: item.intentMismatchRiskPoints,
            ageAnomalies: ageAnomalies,
            ageAnomalyRiskPoints: item.ageAnomalyRiskPoints,
            signedButDangerousFlags: dangerFlags,
            signedButDangerousRisk: item.signedButDangerousRisk,
            plistCreatedAt: item.plistCreatedAt.map { dateFormatter.string(from: $0) },
            plistModifiedAt: item.plistModifiedAt.map { dateFormatter.string(from: $0) },
            binaryCreatedAt: item.binaryCreatedAt.map { dateFormatter.string(from: $0) },
            binaryModifiedAt: item.binaryModifiedAt.map { dateFormatter.string(from: $0) },
            discoveredAt: dateFormatter.string(from: item.discoveredAt),
            systemInfo: SystemInfo(
                hostname: Host.current().localizedName ?? "Unknown",
                macosVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
        )
    }

    // MARK: - API Call

    /// Analyze persistence diff with Claude
    func analyzeDiff(_ request: AnalysisRequest) async throws -> AnalysisResponse {
        var systemPrompt = """
        You are a macOS security analyst. Analyze the following persistence changes and current state.

        Your task:
        1. Identify suspicious new persistence items
        2. Detect known malware patterns
        3. Flag risky configurations
        4. Map findings to MITRE ATT&CK techniques where applicable

        Respond with JSON matching this exact schema:
        {
          "severity": "info|low|medium|high|critical",
          "summary": "Brief 1-2 sentence summary of findings",
          "findings": [
            {
              "severity": "info|low|medium|high|critical",
              "title": "Short finding title",
              "description": "Detailed explanation",
              "affectedItems": ["item identifiers"],
              "mitreTechniques": ["T1543.001", "T1059.004"]
            }
          ],
          "recommendations": ["Action item 1", "Action item 2"]
        }

        Severity guidelines:
        - critical: Active malware indicators, backdoors, known APT techniques
        - high: Unsigned items in sensitive locations, suspicious LOLBins usage, risky entitlements
        - medium: New third-party persistence, modified configurations, expired certificates
        - low: New items from known vendors, minor configuration changes
        - info: Expected system changes, Apple updates

        Be concise but thorough. Prioritize actionable findings.
        """

        // Append user-configured prompt options
        let promptAdditions = configuration.fullAnalysisPrompt
        if !promptAdditions.isEmpty {
            systemPrompt += promptAdditions
        }

        let userMessage = try JSONEncoder().encode(request)

        let body: [String: Any] = [
            "model": configuration.claudeModel,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": String(data: userMessage, encoding: .utf8)!]
            ]
        ]

        var urlRequest = URLRequest(url: apiURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(configuration.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeAPIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Parse Claude response
        let claudeResponse = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)

        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }),
              let text = textContent.text,
              let jsonData = text.data(using: .utf8) else {
            throw ClaudeAPIError.noTextContent
        }

        // Parse the JSON from Claude's response
        do {
            return try JSONDecoder().decode(AnalysisResponse.self, from: jsonData)
        } catch {
            // Try to extract JSON from markdown code block
            if let extracted = extractJSON(from: text) {
                return try JSONDecoder().decode(AnalysisResponse.self, from: extracted)
            }
            throw ClaudeAPIError.invalidJSON(text)
        }
    }

    private func extractJSON(from text: String) -> Data? {
        // Try to extract JSON from ```json ... ``` block
        let pattern = "```(?:json)?\\s*\\n?([\\s\\S]*?)\\n?```"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range]).data(using: .utf8)
    }

    // MARK: - Generic transport (shared with ItemAnalyst)

    /// Sends a chat request and returns the model's raw text content.
    /// Used by callers that need to parse a custom JSON schema (e.g. ItemAnalyst).
    func chatRaw(
        systemPrompt: String,
        userJSON: String,
        model: String? = nil,
        maxTokens: Int = 1024
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model ?? configuration.claudeModel,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userJSON]
            ]
        ]

        var urlRequest = URLRequest(url: apiURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(configuration.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Use an explicit URLSessionDataTask wrapped in a cancellation handler
        // so Swift `Task.cancel()` actually aborts the in-flight HTTP request.
        // Without this, BulkAnalysisCoordinator.cancel() can take 30+s to exit
        // because URLSession.data(for:) ignores cooperative cancellation.
        let dataTaskBox = DataTaskBox()
        let (data, response): (Data, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = self.session.dataTask(with: urlRequest) { data, response, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data, let response = response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: ClaudeAPIError.invalidResponse)
                    }
                }
                dataTaskBox.set(task)
                task.resume()
            }
        } onCancel: {
            dataTaskBox.cancel()
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeAPIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        let claudeResponse = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)
        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }),
              let text = textContent.text else {
            throw ClaudeAPIError.noTextContent
        }
        return text
    }

    /// Thread-safe holder for a URLSessionDataTask reference, so the cancel
    /// handler can reach into the running request from outside the continuation.
    private final class DataTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?

        func set(_ t: URLSessionDataTask) {
            lock.lock(); defer { lock.unlock() }
            task = t
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            task?.cancel()
        }
    }

    /// Decodes a JSON object from raw text, tolerating model verbosity.
    /// Strategy: direct → ```json``` fence → outermost `{...}` span. Logs the
    /// raw response when all three fail so we can iterate on the prompt.
    func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        if let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(T.self, from: data) {
            return decoded
        }
        if let fenced = extractJSON(from: text),
           let decoded = try? JSONDecoder().decode(T.self, from: fenced) {
            return decoded
        }
        if let braced = extractBracedJSON(from: text),
           let decoded = try? JSONDecoder().decode(T.self, from: braced) {
            return decoded
        }
        NSLog("[ClaudeAPIClient] decodeJSON failed. Raw text:\n%@", text)
        Self.appendFailureLog(rawText: text, expecting: String(describing: T.self))
        throw ClaudeAPIError.invalidJSON(text)
    }

    /// Persists failed JSON responses to ~/Library/Logs/MacPersistenceChecker/ai_failures.log
    /// so the user can inspect them without diving into Console.app.
    private static func appendFailureLog(rawText: String, expecting type: String) {
        let logsDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MacPersistenceChecker", isDirectory: true)
        let logFile = logsDir.appendingPathComponent("ai_failures.log")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = """

        ===== \(timestamp) — failed to decode \(type) =====
        \(rawText)


        """

        guard let data = entry.data(using: .utf8) else { return }

        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: logFile)
        }
    }

    /// Finds the first balanced JSON object inside the text, ignoring any
    /// preamble (e.g. "Here is the analysis:" or "```json"), trailing prose,
    /// or trailing fence. Tracks string boundaries so braces inside strings
    /// don't break the count. Returns nil only if the text never balances.
    private func extractBracedJSON(from text: String) -> Data? {
        guard let firstBrace = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var endIdx: String.Index? = nil

        var idx = firstBrace
        while idx < text.endIndex {
            let ch = text[idx]
            if escape {
                escape = false
            } else if inString {
                if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"":
                    inString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        endIdx = idx
                    }
                default:
                    break
                }
            }
            if endIdx != nil { break }
            idx = text.index(after: idx)
        }

        guard let end = endIdx else { return nil }
        return String(text[firstBrace...end]).data(using: .utf8)
    }

    // MARK: - Single Item Analysis

    /// Analyze a single changed persistence item with full details
    func analyzeItem(_ analysis: DetailedItemAnalysis) async throws -> SingleItemAnalysisResponse {
        var systemPrompt = """
        You are a macOS security analyst. A persistence item has been \(analysis.changeType) on this system.
        Analyze all the provided details and decide if this warrants a security notification.

        You have complete information about:
        - The persistence mechanism type and configuration
        - Code signature status and validity
        - Risk scores and specific risk factors
        - LOLBins (Living-off-the-Land Binaries) detections
        - Behavioral anomalies
        - Intent mismatches between plist config and binary behavior
        - Age anomalies (suspicious timing patterns)
        - Signed-but-dangerous indicators

        Respond with JSON matching this exact schema:
        {
          "shouldNotify": true/false,
          "severity": "info|low|medium|high|critical",
          "title": "Short notification title (max 50 chars)",
          "explanation": "Clear explanation of why this is or isn't suspicious (2-3 sentences)",
          "recommendation": "What the user should do (optional, null if not needed)",
          "mitreTechniques": ["T1543.001"] // MITRE ATT&CK techniques if applicable, null otherwise
        }

        Decision guidelines:
        - shouldNotify: true if the user should be alerted about this change
        - critical: Active malware indicators, known APT techniques, backdoor behavior
        - high: Unsigned in sensitive locations, LOLBins abuse, suspicious entitlements, multiple red flags
        - medium: New third-party persistence, expired certs, single concerning indicator
        - low: Known vendor but unusual config, minor anomalies
        - info: Expected system behavior, Apple updates, trusted software

        Consider the full context: a signed item from a known vendor with no anomalies is likely safe,
        while an unsigned item with LOLBins usage and age anomalies deserves attention.
        """

        // Append user-configured prompt options
        let promptAdditions = configuration.fullAnalysisPrompt
        if !promptAdditions.isEmpty {
            systemPrompt += promptAdditions
        }

        let userMessage = try JSONEncoder().encode(analysis)

        let body: [String: Any] = [
            "model": configuration.claudeModel,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": String(data: userMessage, encoding: .utf8)!]
            ]
        ]

        var urlRequest = URLRequest(url: apiURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(configuration.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeAPIError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Parse Claude response
        let claudeResponse = try JSONDecoder().decode(ClaudeAPIResponse.self, from: data)

        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }),
              let text = textContent.text,
              let jsonData = text.data(using: .utf8) else {
            throw ClaudeAPIError.noTextContent
        }

        // Parse the JSON from Claude's response
        do {
            return try JSONDecoder().decode(SingleItemAnalysisResponse.self, from: jsonData)
        } catch {
            // Try to extract JSON from markdown code block
            if let extracted = extractJSON(from: text) {
                return try JSONDecoder().decode(SingleItemAnalysisResponse.self, from: extracted)
            }
            throw ClaudeAPIError.invalidJSON(text)
        }
    }

    // MARK: - Claude API Response Types

    private struct ClaudeAPIResponse: Codable {
        let id: String
        let type: String
        let role: String
        let content: [ContentBlock]
        let model: String
        let stopReason: String?
        let usage: Usage?

        enum CodingKeys: String, CodingKey {
            case id, type, role, content, model
            case stopReason = "stop_reason"
            case usage
        }
    }

    private struct ContentBlock: Codable {
        let type: String
        let text: String?
    }

    private struct Usage: Codable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

// MARK: - Errors

enum ClaudeAPIError: Error, LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case noTextContent
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Claude API"
        case .apiError(let code, let message):
            if code == 401 {
                return "Invalid API key. Please check your Claude API key."
            }
            if code == 429 {
                return "Rate limit exceeded. Please try again later."
            }
            return "API error (\(code)): \(message)"
        case .noTextContent:
            return "No text content in Claude response"
        case .invalidJSON(let text):
            return "Failed to parse Claude response as JSON: \(text.prefix(200))..."
        }
    }
}
