import Foundation
import Security

/// Prompt analysis options - structured settings for AI behavior
struct AIPromptOptions: Codable, Equatable {
    /// Ignore items signed by Apple
    var ignoreAppleSigned: Bool = true
    /// Ignore system paths (/System, /Library)
    var ignoreSystemPaths: Bool = true
    /// Prioritize unsigned items
    var prioritizeUnsigned: Bool = true
    /// Focus on LOLBins detection
    var focusLOLBins: Bool = true
    /// Minimum risk score to analyze (0-100)
    var minimumRiskScore: Int = 0
    /// Custom paths to ignore (comma-separated)
    var ignoredPaths: String = ""

    /// Generate prompt additions based on options
    var promptAdditions: String {
        var additions: [String] = []

        if ignoreAppleSigned {
            additions.append("- Ignore or deprioritize items that are signed by Apple (com.apple.*)")
        }
        if ignoreSystemPaths {
            additions.append("- Deprioritize items in /System and /Library paths as they are typically system components")
        }
        if prioritizeUnsigned {
            additions.append("- Pay special attention to unsigned executables - these are higher risk")
        }
        if focusLOLBins {
            additions.append("- Focus on detecting Living-off-the-Land Binaries (LOLBins) usage patterns")
        }
        if minimumRiskScore > 0 {
            additions.append("- Only analyze items with risk score >= \(minimumRiskScore)")
        }
        if !ignoredPaths.isEmpty {
            additions.append("- Ignore items in these paths: \(ignoredPaths)")
        }

        return additions.isEmpty ? "" : "\n\nAnalysis preferences:\n" + additions.joined(separator: "\n")
    }
}

/// Severity levels for AI analysis
enum AISeverity: String, CaseIterable, Comparable, Codable {
    case info = "info"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case critical = "critical"

    var displayName: String {
        rawValue.capitalized
    }

    static func < (lhs: AISeverity, rhs: AISeverity) -> Bool {
        let order: [AISeverity] = [.info, .low, .medium, .high, .critical]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
    }
}

/// AI Configuration manager
@MainActor
final class AIConfiguration: ObservableObject {
    static let shared = AIConfiguration()

    // MARK: - AI Enable (requires API key)

    /// Whether to use AI for analysis (only works if API key is valid)
    @Published var useAI: Bool {
        didSet { saveSettings() }
    }

    // MARK: - Claude API Settings

    @Published var claudeAPIKey: String {
        didSet {
            if !claudeAPIKey.isEmpty {
                saveAPIKeyToKeychain()
            } else {
                // If key is cleared, disable AI
                useAI = false
            }
        }
    }

    @Published var claudeModel: String {
        didSet { saveSettings() }
    }

    /// Lightweight model for on-demand item analysis (cheaper, used by ItemAnalyst).
    @Published var haikuModel: String {
        didSet { saveSettings() }
    }

    /// Heavyweight model for narrative system reports — better at long-form
    /// synthesis than Haiku. Used by HealthReportGenerator. Costs ~$3/MTok
    /// input vs Haiku's ~$1, so reserved for high-value one-shot reports.
    @Published var sonnetModel: String {
        didSet { saveSettings() }
    }

    // MARK: - On-demand AI cap

    /// Maximum AI calls allowed per day (hard cap to bound cost).
    @Published var dailyCallCap: Int {
        didSet { saveSettings() }
    }

    /// AI calls already made today. Auto-resets when the date rolls over.
    @Published private(set) var callsTodayCount: Int

    /// Date stamp of the current counter window (start of day).
    private var callsCounterDate: Date

    /// True if the daily cap allows another call right now.
    var canMakeCall: Bool {
        rolloverIfNeeded()
        return callsTodayCount < dailyCallCap
    }

    var callsRemainingToday: Int {
        rolloverIfNeeded()
        return max(0, dailyCallCap - callsTodayCount)
    }

    /// Records that a call was made. Persists immediately.
    func recordCall() {
        rolloverIfNeeded()
        callsTodayCount += 1
        saveSettings()
    }

    /// Rolls the counter over to a new day if the date has changed.
    private func rolloverIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if today != callsCounterDate {
            callsCounterDate = today
            callsTodayCount = 0
            saveSettings()
        }
    }

    // MARK: - AI Analysis Settings

    /// AI check interval in seconds (used by monitoring when AI is enabled)
    @Published var aiCheckInterval: TimeInterval {
        didSet { saveSettings() }
    }

    /// Minimum severity to trigger notifications
    @Published var notificationThreshold: AISeverity {
        didSet { saveSettings() }
    }

    // MARK: - Prompt Settings

    /// Structured prompt options
    @Published var promptOptions: AIPromptOptions {
        didSet { saveSettings() }
    }

    /// Custom prompt text (appended to default)
    @Published var customPrompt: String {
        didSet { saveSettings() }
    }

    // MARK: - MCP Settings

    /// Whether MCP server is enabled
    @Published var mcpServerEnabled: Bool {
        didSet { saveSettings() }
    }

    /// Path to mpc-server binary
    @Published var mcpServerPath: String {
        didSet { saveSettings() }
    }

    // MARK: - Initialization

    private let keychainService = "com.macpersistencechecker.claude-api"
    private let settingsKey = "ai_configuration_v2"

    private init() {
        // Load defaults
        self.useAI = false
        self.claudeAPIKey = ""
        self.claudeModel = "claude-sonnet-4-20250514"
        self.haikuModel = "claude-haiku-4-5-20251001"
        self.sonnetModel = "claude-sonnet-4-6"
        self.dailyCallCap = 30
        self.callsTodayCount = 0
        self.callsCounterDate = Calendar.current.startOfDay(for: Date())
        self.aiCheckInterval = 300 // 5 minutes
        self.notificationThreshold = .medium
        self.promptOptions = AIPromptOptions()
        self.customPrompt = ""
        self.mcpServerEnabled = false
        self.mcpServerPath = ""

        // Load saved settings
        loadSettings()
        loadAPIKeyFromKeychain()

        // Try to find MCP server binary
        if mcpServerPath.isEmpty {
            findMCPServerBinary()
        }

        // Ensure useAI is false if no valid key
        if !isAPIKeyValid {
            useAI = false
        }
    }

    // MARK: - Settings Persistence

    private struct SavedSettings: Codable {
        let useAI: Bool
        let claudeModel: String
        let aiCheckInterval: TimeInterval
        let notificationThreshold: String
        let promptOptions: AIPromptOptions
        let customPrompt: String
        let mcpServerEnabled: Bool
        let mcpServerPath: String
        // Phase 2 additions — optional for backwards compat with v2 saves
        let haikuModel: String?
        let dailyCallCap: Int?
        let callsTodayCount: Int?
        let callsCounterDate: TimeInterval?
        let sonnetModel: String?
    }

    private func saveSettings() {
        let settings = SavedSettings(
            useAI: useAI,
            claudeModel: claudeModel,
            aiCheckInterval: aiCheckInterval,
            notificationThreshold: notificationThreshold.rawValue,
            promptOptions: promptOptions,
            customPrompt: customPrompt,
            mcpServerEnabled: mcpServerEnabled,
            mcpServerPath: mcpServerPath,
            haikuModel: haikuModel,
            dailyCallCap: dailyCallCap,
            callsTodayCount: callsTodayCount,
            callsCounterDate: callsCounterDate.timeIntervalSince1970,
            sonnetModel: sonnetModel
        )

        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(SavedSettings.self, from: data) else {
            return
        }

        self.useAI = settings.useAI
        self.claudeModel = settings.claudeModel
        self.aiCheckInterval = settings.aiCheckInterval
        if let threshold = AISeverity(rawValue: settings.notificationThreshold) {
            self.notificationThreshold = threshold
        }
        self.promptOptions = settings.promptOptions
        self.customPrompt = settings.customPrompt
        self.mcpServerEnabled = settings.mcpServerEnabled
        self.mcpServerPath = settings.mcpServerPath
        if let h = settings.haikuModel { self.haikuModel = h }
        if let cap = settings.dailyCallCap { self.dailyCallCap = cap }
        if let count = settings.callsTodayCount { self.callsTodayCount = count }
        if let dateInterval = settings.callsCounterDate {
            self.callsCounterDate = Date(timeIntervalSince1970: dateInterval)
        }
        if let s = settings.sonnetModel { self.sonnetModel = s }
    }

    // MARK: - Keychain

    private func saveAPIKeyToKeychain() {
        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !claudeAPIKey.isEmpty else { return }

        // Add new
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecValueData as String: claudeAPIKey.data(using: .utf8)!
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("[AIConfiguration] Failed to save API key to Keychain: \(status)")
        }
    }

    private func loadAPIKeyFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            self.claudeAPIKey = String(data: data, encoding: .utf8) ?? ""
        }
    }

    // MARK: - MCP Server

    private func findMCPServerBinary() {
        // Check common locations
        let possiblePaths = [
            // Build directory
            FileManager.default.currentDirectoryPath + "/.build/debug/mpc-server",
            FileManager.default.currentDirectoryPath + "/.build/release/mpc-server",
            // App bundle
            Bundle.main.bundlePath + "/Contents/MacOS/mpc-server",
            // User local
            FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/mpc-server",
            "/usr/local/bin/mpc-server"
        ]

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                mcpServerPath = path
                break
            }
        }
    }

    /// Validate API key format
    var isAPIKeyValid: Bool {
        claudeAPIKey.hasPrefix("sk-ant-") && claudeAPIKey.count > 20
    }

    /// Check if MCP server is available
    var isMCPServerAvailable: Bool {
        !mcpServerPath.isEmpty && FileManager.default.fileExists(atPath: mcpServerPath)
    }

    /// Generate Claude Code MCP config snippet
    var mcpConfigSnippet: String {
        """
        {
          "mcpServers": {
            "mac-persistence": {
              "command": "\(mcpServerPath)",
              "args": []
            }
          }
        }
        """
    }

    /// Available Claude models
    static let availableModels = [
        ("claude-sonnet-4-20250514", "Claude Sonnet 4 (Recommended)"),
        ("claude-opus-4-20250514", "Claude Opus 4 (Most Capable)"),
        ("claude-3-5-haiku-20241022", "Claude 3.5 Haiku (Fastest)")
    ]

    /// AI check interval options
    static let intervalOptions: [(TimeInterval, String)] = [
        (30, "30 seconds"),
        (60, "1 minute"),
        (120, "2 minutes"),
        (300, "5 minutes"),
        (600, "10 minutes"),
        (900, "15 minutes"),
        (1800, "30 minutes"),
        (3600, "1 hour")
    ]

    /// Whether AI analysis is available (key is valid)
    var isAIAvailable: Bool {
        isAPIKeyValid
    }

    /// Whether AI is actively enabled and available
    var isAIActive: Bool {
        useAI && isAPIKeyValid
    }

    /// Full prompt including default + options + custom
    var fullAnalysisPrompt: String {
        var prompt = promptOptions.promptAdditions
        if !customPrompt.isEmpty {
            prompt += "\n\nAdditional instructions:\n\(customPrompt)"
        }
        return prompt
    }
}
