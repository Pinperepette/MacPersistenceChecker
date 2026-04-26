import SwiftUI

/// Settings view for AI integration
struct AISettingsView: View {
    @StateObject private var config = AIConfiguration.shared

    @State private var showAPIKeyField = false
    @State private var testingAPI = false
    @State private var testResult: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider()
                apiKeySection

                if config.isAIAvailable {
                    Divider()
                    analysisSettingsSection
                    Divider()
                    promptOptionsSection
                }

                Divider()
                mcpServerSection

                Spacer(minLength: 20)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain")
                    .font(.title)
                    .foregroundColor(.accentColor)
                Text("AI Integration")
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Text("Configure Claude AI for intelligent analysis. Once configured, enable AI from the Monitoring tab.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - API Key Section

    private var apiKeySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Claude API Key")
                    .font(.headline)

                Text("Get your API key from console.anthropic.com")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    if showAPIKeyField {
                        SecureField("sk-ant-...", text: $config.claudeAPIKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Text(config.claudeAPIKey.isEmpty ? "Not configured" : maskAPIKey(config.claudeAPIKey))
                            .foregroundColor(config.claudeAPIKey.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(showAPIKeyField ? "Done" : "Edit") {
                        showAPIKeyField.toggle()
                    }
                    .buttonStyle(.bordered)
                }

                if !config.claudeAPIKey.isEmpty && !config.isAPIKeyValid {
                    Label("API key should start with 'sk-ant-'", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if config.isAPIKeyValid {
                    HStack {
                        Label("API key configured", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)

                        Spacer()

                        if testingAPI {
                            ProgressView()
                                .scaleEffect(0.7)
                        }

                        Button("Test Connection") {
                            testAPIConnection()
                        }
                        .buttonStyle(.bordered)
                        .disabled(testingAPI)
                    }

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("Success") ? .green : .red)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Analysis Settings Section

    private var analysisSettingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Analysis Settings")
                    .font(.headline)

                // Model Selection
                HStack {
                    Text("Model")
                        .frame(width: 120, alignment: .leading)

                    Picker("", selection: $config.claudeModel) {
                        ForEach(AIConfiguration.availableModels, id: \.0) { model in
                            Text(model.1).tag(model.0)
                        }
                    }
                    .labelsHidden()
                }

                // Check Interval
                HStack {
                    Text("Check Interval")
                        .frame(width: 120, alignment: .leading)

                    Picker("", selection: $config.aiCheckInterval) {
                        ForEach(AIConfiguration.intervalOptions, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                    .labelsHidden()

                    Text("(used by Monitoring)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Notification Threshold
                HStack {
                    Text("Notify when")
                        .frame(width: 120, alignment: .leading)

                    Picker("", selection: $config.notificationThreshold) {
                        ForEach(AISeverity.allCases, id: \.self) { severity in
                            Text("Severity \u{2265} \(severity.displayName)").tag(severity)
                        }
                    }
                    .labelsHidden()
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Prompt Options Section

    private var promptOptionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Analysis Behavior")
                    .font(.headline)

                Text("Configure how Claude analyzes persistence items")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Ignore Apple-signed items", isOn: $config.promptOptions.ignoreAppleSigned)
                    Toggle("Deprioritize system paths (/System, /Library)", isOn: $config.promptOptions.ignoreSystemPaths)
                    Toggle("Prioritize unsigned executables", isOn: $config.promptOptions.prioritizeUnsigned)
                    Toggle("Focus on LOLBins detection", isOn: $config.promptOptions.focusLOLBins)
                }
                .font(.subheadline)

                Divider()

                // Minimum Risk Score
                HStack {
                    Text("Min. risk score")
                        .frame(width: 120, alignment: .leading)

                    Picker("", selection: $config.promptOptions.minimumRiskScore) {
                        Text("All items (0)").tag(0)
                        Text("Low+ (20)").tag(20)
                        Text("Medium+ (40)").tag(40)
                        Text("High+ (60)").tag(60)
                        Text("Critical only (80)").tag(80)
                    }
                    .labelsHidden()
                }

                Divider()

                // Ignored Paths
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ignored paths (comma-separated)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("e.g., /opt/homebrew, ~/Library/Caches", text: $config.promptOptions.ignoredPaths)
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                // Custom Prompt
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom instructions (optional)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextEditor(text: $config.customPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 80)
                        .border(Color.gray.opacity(0.3), width: 1)

                    Text("Add custom instructions for Claude's analysis. These are appended to the default prompt.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - MCP Server Section

    private var mcpServerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $config.mcpServerEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MCP Server")
                            .font(.headline)
                        Text("Expose MCP tools for Claude Code / Claude Desktop")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if config.mcpServerEnabled {
                    Divider()

                    // Server Status
                    HStack {
                        Image(systemName: "terminal")
                            .foregroundColor(.accentColor)
                        Text("Server Binary")

                        Spacer()

                        if config.isMCPServerAvailable {
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Label("Not Found", systemImage: "xmark.circle.fill")
                                .foregroundColor(.red)
                        }
                    }

                    if !config.isMCPServerAvailable {
                        Text("Build the MCP server: swift build --target MPCServer")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Path configuration
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server Path")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("Path to mpc-server", text: $config.mcpServerPath)
                                .textFieldStyle(.roundedBorder)

                            Button("Browse...") {
                                browseForServer()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Divider()

                    // Available Tools
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Available Tools")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        VStack(alignment: .leading, spacing: 4) {
                            ToolRow(name: "get_current_state", description: "Current persistence items")
                            ToolRow(name: "get_diff", description: "Diff from baseline")
                            ToolRow(name: "get_summary", description: "Compact summary")
                            ToolRow(name: "get_item_details", description: "Item details")
                            ToolRow(name: "get_risk_analysis", description: "Risk analysis")
                            ToolRow(name: "get_snapshots", description: "List snapshots")
                            ToolRow(name: "compare_snapshots", description: "Compare snapshots")
                        }
                    }

                    Divider()

                    // Config snippet
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Claude Code Configuration")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            Spacer()

                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(config.mcpConfigSnippet, forType: .string)
                            }
                            .buttonStyle(.bordered)
                        }

                        Text("Add this to your Claude Code MCP settings:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(config.mcpConfigSnippet)
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .background(Color.black.opacity(0.05))
                                .cornerRadius(4)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    private func maskAPIKey(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "*", count: key.count) }
        let prefix = String(key.prefix(7))
        let suffix = String(key.suffix(4))
        return "\(prefix)...\(suffix)"
    }

    private func testAPIConnection() {
        testingAPI = true
        testResult = nil

        Task {
            do {
                let client = ClaudeAPIClient()
                let testRequest = ClaudeAPIClient.AnalysisRequest(
                    diffSummary: "Test connection",
                    addedItems: [],
                    removedItems: [],
                    modifiedItems: [],
                    currentStats: ClaudeAPIClient.SystemStats(
                        totalItems: 0,
                        unsignedCount: 0,
                        criticalRiskCount: 0,
                        highRiskCount: 0,
                        lolbinItemCount: 0
                    ),
                    systemInfo: ClaudeAPIClient.SystemInfo(
                        hostname: "test",
                        macosVersion: "test"
                    )
                )
                _ = try await client.analyzeDiff(testRequest)
                await MainActor.run {
                    testResult = "Success! API connection working."
                    testingAPI = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    testingAPI = false
                }
            }
        }
    }

    private func browseForServer() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the mpc-server binary"

        if panel.runModal() == .OK, let url = panel.url {
            config.mcpServerPath = url.path
        }
    }
}

// MARK: - Supporting Views

private struct ToolRow: View {
    let name: String
    let description: String

    var body: some View {
        HStack {
            Image(systemName: "function")
                .foregroundColor(.accentColor)
                .frame(width: 16)

            Text(name)
                .font(.system(.caption, design: .monospaced))

            Text("-")
                .foregroundColor(.secondary)

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
    }
}

#if XCODE_PREVIEWS
#Preview {
    AISettingsView()
        .frame(width: 600, height: 800)
}
#endif
