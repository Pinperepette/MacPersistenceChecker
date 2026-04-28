import Foundation

/// In-bundle JSON describing path/bundle/filename hints for the deterministic
/// concept extractors. Loaded once and cached for the lifetime of the app.
struct ConceptHints: Codable {
    let version: Int
    let pathHints: [PathHint]
    let bundleHints: [BundleHint]
    let filenamePatterns: [FilenameHint]
}

struct PathHint: Codable {
    let id: String
    let displayName: String
    let prefix: String
    /// If true, the prefix is matched against the path with the user's home
    /// directory stripped (e.g. matches `Library/LaunchAgents/`).
    let userRelative: Bool

    private enum CodingKeys: String, CodingKey {
        case id, displayName, prefix, userRelative
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.prefix = try c.decode(String.self, forKey: .prefix)
        self.userRelative = try c.decodeIfPresent(Bool.self, forKey: .userRelative) ?? false
    }
}

struct BundleHint: Codable {
    let id: String
    let displayName: String
    let prefix: String
}

struct FilenameHint: Codable {
    let id: String
    let displayName: String
    let regex: String

    /// Lazily compiled NSRegularExpression. `nil` if the pattern is invalid.
    var compiledRegex: NSRegularExpression? {
        try? NSRegularExpression(pattern: regex)
    }
}

/// Loads `Resources/ConceptHints.json` once. Falls back to a minimal hardcoded
/// set if the resource is missing (e.g. broken bundling), so the pipeline still
/// emits something useful.
final class ConceptHintsLoader: @unchecked Sendable {
    static let shared = ConceptHintsLoader()

    private let lock = NSLock()
    private var cached: ConceptHints?

    private init() {}

    func load() -> ConceptHints {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }

        if let url = Bundle.main.url(forResource: "ConceptHints", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ConceptHints.self, from: data) {
            cached = decoded
            return decoded
        }

        NSLog("[ConceptHintsLoader] Resource missing, using fallback")
        let fallback = ConceptHints(
            version: 0,
            pathHints: [
                PathHint(_id: "path:/opt/homebrew", displayName: "Homebrew", prefix: "/opt/homebrew/", userRelative: false),
                PathHint(_id: "path:/usr/local/lib", displayName: "Homebrew (Intel) — lib", prefix: "/usr/local/lib/", userRelative: false),
                PathHint(_id: "path:/Library/LaunchDaemons", displayName: "System LaunchDaemons", prefix: "/Library/LaunchDaemons/", userRelative: false)
            ],
            bundleHints: [
                BundleHint(id: "pattern:com.apple", displayName: "Apple bundle ID", prefix: "com.apple."),
                BundleHint(id: "pattern:homebrew.mxcl", displayName: "Homebrew launchctl service", prefix: "homebrew.mxcl.")
            ],
            filenamePatterns: []
        )
        cached = fallback
        return fallback
    }
}

// MARK: - Convenience for fallback initializer

private extension PathHint {
    init(_id: String, displayName: String, prefix: String, userRelative: Bool) {
        self.id = _id
        self.displayName = displayName
        self.prefix = prefix
        self.userRelative = userRelative
    }
}
