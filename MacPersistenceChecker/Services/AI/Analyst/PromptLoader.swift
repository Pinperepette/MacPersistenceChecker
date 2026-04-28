import Foundation

/// Loads AI prompts from the bundle's Resources/AIPrompts directory.
///
/// Keeping prompts as separate files means we can iterate on them without
/// recompiling the app, and the user can view (or override) them by editing
/// the bundled markdown.
enum PromptLoader {

    enum Prompt: String {
        case itemAnalyst = "item_analyst"
        case clusterAnalyst = "cluster_analyst"
        case healthReport = "health_report_analyst"
        case snapshotDiff = "snapshot_diff_analyst"
        case threatHunt = "threat_hunt_analyst"
    }

    /// In-memory cache. Cleared on app launch (no need for invalidation while running).
    private static var cache: [String: String] = [:]

    /// Loads the prompt text. Returns a fallback string if the file is missing
    /// so the analyst still works (with a warning logged).
    static func load(_ prompt: Prompt) -> String {
        if let cached = cache[prompt.rawValue] {
            return cached
        }

        if let url = Bundle.main.url(
            forResource: prompt.rawValue,
            withExtension: "md",
            subdirectory: "AIPrompts"
        ) ?? Bundle.main.url(
            forResource: prompt.rawValue,
            withExtension: "md"
        ),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            cache[prompt.rawValue] = text
            return text
        }

        NSLog("[PromptLoader] Missing prompt resource: %@.md — using fallback", prompt.rawValue)
        let fallback = Self.fallback(for: prompt)
        cache[prompt.rawValue] = fallback
        return fallback
    }

    private static func fallback(for prompt: Prompt) -> String {
        switch prompt {
        case .itemAnalyst:
            return """
            You are a macOS persistence security analyst.
            Output one JSON object: { "verdict": "benign|watchlist|malicious",
            "confidence": 0.0-1.0, "explanation": "...", "mitreTechniques": null,
            "extractedRule": null }. Be conservative; reserve "malicious" for
            concrete indicators only.
            """
        case .clusterAnalyst:
            return """
            You are a macOS persistence cluster analyst.
            For each cluster in the input, output a verdict object. Output one
            JSON object: { "clusters": [{ "id": "...", "verdict":
            "benign|watchlist|malicious", "confidence": 0.0-1.0,
            "attachToConcept": "...", "rationale": "..." }] }. Default to
            benign for package-manager paths and vendor:apple clusters.
            """
        case .healthReport:
            return """
            Write a brief markdown health report (Overall posture, What's
            running, Items worth a second look, Recommended next actions).
            Concise, no fluff, no JSON wrapper.
            """
        case .snapshotDiff:
            return """
            Summarize the diff between two persistence snapshots. Output one
            JSON object: { "summary": "1-2 sentence headline",
            "added": [{"name":"...","explanation":"..."}],
            "removed": [{"name":"...","explanation":"..."}],
            "modified": [{"name":"...","explanation":"..."}] }.
            """
        case .threatHunt:
            return """
            Answer a natural-language question about persistence items.
            Output one JSON object: { "matchedItemIDs": ["..."],
            "rationale": "...", "mitreTechniques": ["..."] | null }.
            """
        }
    }
}
