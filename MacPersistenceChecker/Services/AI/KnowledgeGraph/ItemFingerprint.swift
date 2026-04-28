import Foundation
import CryptoKit

/// Identity-based fingerprint of a PersistenceItem.
///
/// Uses only attributes that don't change across analyzer-version upgrades:
/// teamID, normalized paths, bundleIdentifier, category. No behavioral fields.
///
/// A future v2 may add a `strongHash` (sha256 of binary + plist) for tamper detection;
/// kept out of v1 to avoid file I/O on every lookup.
struct ItemFingerprint: Equatable, Hashable, Codable {
    let teamID: String?
    let pathNormalized: String
    let bundleIdentifier: String?
    let category: String

    /// Stable hash derived from the canonical fingerprint fields.
    /// Used as the unique key in `knowledgeFingerprints`.
    var hash: String {
        let canonical = [
            "team:\(teamID ?? "")",
            "path:\(pathNormalized)",
            "bundle:\(bundleIdentifier ?? "")",
            "cat:\(category)"
        ].joined(separator: "|")

        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func make(from item: PersistenceItem) -> ItemFingerprint {
        let plistPathString = item.plistPath?.path ?? ""
        let execPathString = item.executablePath?.path ?? ""
        // Combine plist + exec paths so that items sharing a binary but different plists
        // (or vice versa) don't collide.
        let combined = "\(normalize(plistPathString))::\(normalize(execPathString))"

        return ItemFingerprint(
            teamID: item.signatureInfo?.teamIdentifier,
            pathNormalized: combined,
            bundleIdentifier: item.bundleIdentifier,
            category: item.category.rawValue
        )
    }

    /// Replaces the user's home directory with `~` so fingerprints are portable
    /// across different user accounts on the same machine.
    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
