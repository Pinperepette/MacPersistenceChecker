import Foundation

/// Derives a `software:*` concept from vendor-agnostic, structural signals only.
///
/// Three sources, in order of confidence:
/// 1. **parentAppPath / `.app` segment in the path** — universally reliable: the
///    parent macOS application bundle name is the software.
/// 2. **Package-manager directory layouts** — `/Cellar/<name>/<version>/`,
///    `/Caskroom/<name>/`, `/opt/<name>/`, `/opt/local/var/macports/sources/<name>/`.
///    Works for Intel Homebrew, Apple-Silicon Homebrew, casks, and MacPorts
///    without hardcoding any of them.
/// 3. **Application Support direct child** — `Library/Application Support/<X>/...`
///    where `<X>` is the software name. Sub-classifies the largest cluster on
///    most systems.
///
/// We deliberately do NOT slice the bundle identifier ("middle segment = software")
/// because that assumption is invalid for any reverse-DNS scheme that uses
/// the middle for a category (Apple's `com.apple.driver.X`, Microsoft's
/// `com.microsoft.OneDrive.X`, freedesktop, JetBrains, etc.).
struct SoftwareExtractor: ConceptFeatureExtractor {
    let name = "SoftwareExtractor"
    let version = 2

    func extract(from item: PersistenceItem) -> [ConceptSignal] {
        if let signal = fromAppBundle(item) { return [signal] }
        if let signal = fromPackageManagerLayout(item) { return [signal] }
        if let signal = fromApplicationSupport(item) { return [signal] }
        return []
    }

    // MARK: - Sources

    /// 1) Use the parent .app bundle's name when available, either directly via
    /// `parentAppPath` or by walking up the executable / plist path looking for
    /// a `.app` segment.
    private func fromAppBundle(_ item: PersistenceItem) -> ConceptSignal? {
        if let parent = item.parentAppPath {
            let raw = parent.deletingPathExtension().lastPathComponent
            if let signal = makeSoftwareSignal(name: raw, source: "parentAppPath", path: parent.path) {
                return signal
            }
        }
        for path in candidatePaths(item) {
            if let appName = enclosingAppName(in: path),
               let signal = makeSoftwareSignal(name: appName, source: "appBundleInPath", path: path) {
                return signal
            }
        }
        return nil
    }

    /// 2) Match common package-manager directory layouts on macOS. The matchers
    /// are written as fixed prefixes (no regex) and cover both architectures /
    /// installation roots so brew on Intel, brew on Apple Silicon, MacPorts and
    /// casks all work uniformly.
    private func fromPackageManagerLayout(_ item: PersistenceItem) -> ConceptSignal? {
        let layouts: [(prefix: String, label: String)] = [
            ("/opt/homebrew/Cellar/",       "Homebrew Cellar"),
            ("/opt/homebrew/Caskroom/",     "Homebrew Caskroom"),
            ("/opt/homebrew/opt/",          "Homebrew opt"),
            ("/usr/local/Cellar/",          "Homebrew Cellar"),
            ("/usr/local/Caskroom/",        "Homebrew Caskroom"),
            ("/usr/local/opt/",             "Homebrew opt"),
            ("/opt/local/var/macports/sources/", "MacPorts"),
            ("/opt/local/libexec/",         "MacPorts libexec"),
            ("/opt/local/share/",           "MacPorts share")
        ]
        for path in candidatePaths(item) {
            for layout in layouts {
                if let firstSegment = segmentAfterPrefix(in: path, prefix: layout.prefix),
                   let signal = makeSoftwareSignal(
                    name: firstSegment,
                    source: "packageManager(\(layout.label))",
                    path: path
                   ) {
                    return signal
                }
            }
        }
        return nil
    }

    /// 3) `Library/Application Support/<X>/...` — `<X>` is the software vendor /
    /// product folder. Matches both system-wide (`/Library/...`) and user-scoped
    /// (`$HOME/Library/...`) locations.
    private func fromApplicationSupport(_ item: PersistenceItem) -> ConceptSignal? {
        for path in candidatePaths(item) {
            if let firstSegment = segmentAfterPrefix(in: path, prefix: "/Library/Application Support/"),
               let signal = makeSoftwareSignal(
                name: firstSegment,
                source: "applicationSupport",
                path: path
               ) {
                return signal
            }
        }
        return nil
    }

    // MARK: - Helpers

    private func candidatePaths(_ item: PersistenceItem) -> [String] {
        [item.executablePath?.path, item.plistPath?.path].compactMap { $0 }
    }

    /// Returns the first directory name that follows `prefix` in `path`, or nil
    /// if `prefix` isn't found or the segment is empty.
    private func segmentAfterPrefix(in path: String, prefix: String) -> String? {
        guard let range = path.range(of: prefix) else { return nil }
        let tail = path[range.upperBound...]
        guard let endIdx = tail.firstIndex(of: "/") else {
            // The matched prefix is at the end of the path; whatever follows is
            // a single segment if any.
            let bare = String(tail)
            return bare.isEmpty ? nil : bare
        }
        return String(tail[..<endIdx])
    }

    /// Walks the path from right to left, returning the name of the closest
    /// enclosing `.app` bundle (without extension). nil if none.
    private func enclosingAppName(in path: String) -> String? {
        let parts = path.components(separatedBy: "/")
        for part in parts.reversed() where part.hasSuffix(".app") {
            return (part as NSString).deletingPathExtension
        }
        return nil
    }

    /// Validate a candidate name and turn it into a ConceptSignal. Returns nil
    /// if the candidate looks like a file extension, a generic FS dir, or is
    /// otherwise not "software-like".
    private func makeSoftwareSignal(name: String, source: String, path: String) -> ConceptSignal? {
        guard isPlausibleSoftwareName(name) else { return nil }
        let id = sanitizeIdentifier(name)
        guard !id.isEmpty else { return nil }
        return ConceptSignal(
            conceptID: "software:\(id)",
            displayName: name,
            kind: .software,
            signal: "\(source)=\(name) (in \(path))",
            attributes: ["source": source, "name": name]
        )
    }

    /// Generic, vendor-agnostic plausibility check. Rejects file extensions,
    /// generic Unix directory names, anything too short / too long, anything
    /// not starting with a letter.
    private func isPlausibleSoftwareName(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 50 else { return false }
        guard s.first?.isLetter ?? false else { return false }
        guard !s.contains("/") else { return false }

        let lower = s.lowercased()
        if Self.fileExtensionDenylist.contains(lower) { return false }
        if Self.genericDirDenylist.contains(lower) { return false }

        // Allow letters, digits, hyphen, underscore, period, single internal space.
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-_. "))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Lowercased + safe characters only, suitable for use as a concept ID
    /// suffix. Spaces and dots become hyphens; anything outside `[a-z0-9-_]`
    /// is dropped.
    private func sanitizeIdentifier(_ name: String) -> String {
        let normalized = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return String(normalized.unicodeScalars.filter { scalar in
            CharacterSet.lowercaseLetters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "-"
                || scalar == "_"
        })
    }

    // MARK: - Static deny-lists

    /// Common file extensions that show up as "names" when paths leak into the
    /// extractor. Vendor-agnostic.
    private static let fileExtensionDenylist: Set<String> = [
        "json", "png", "jpg", "jpeg", "gif", "bmp", "ico", "svg",
        "plist", "log", "lock", "pid", "tmp", "bak", "old", "swp",
        "pem", "key", "cer", "crt", "p12",
        "txt", "md", "rst", "asciidoc",
        "py", "rb", "sh", "bash", "zsh", "fish", "pl", "lua",
        "conf", "cfg", "ini", "toml", "yaml", "yml",
        "xml", "html", "htm", "css", "js", "mjs", "ts",
        "jar", "war", "ear", "class",
        "zip", "tar", "gz", "bz2", "tgz", "xz", "7z",
        "dat", "db", "sqlite", "sqlite3", "wal", "shm",
        "dylib", "so", "a", "framework"
    ]

    /// Generic Unix / macOS directory names that are clearly NOT software.
    private static let genericDirDenylist: Set<String> = [
        "bin", "sbin", "lib", "lib64", "libexec",
        "etc", "share", "var", "tmp", "log", "logs",
        "cache", "caches", "data", "include", "src",
        "doc", "docs", "man", "info",
        "test", "tests", "build", "dist",
        "macos", "contents", "resources", "frameworks", "plugins",
        "private", "system", "users", "applications", "library"
    ]
}
