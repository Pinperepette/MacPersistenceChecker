import Foundation

/// Extracts forensic timestamp information from files
final class FileTimestampExtractor {

    static let shared = FileTimestampExtractor()

    struct FileTimestamps {
        let createdAt: Date?
        let modifiedAt: Date?
        let accessedAt: Date?  // Last accessed/executed
    }

    /// Get all timestamps for a file
    func getTimestamps(for url: URL) -> FileTimestamps {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FileTimestamps(createdAt: nil, modifiedAt: nil, accessedAt: nil)
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)

            let createdAt = attributes[.creationDate] as? Date
            let modifiedAt = attributes[.modificationDate] as? Date

            // Get access time using stat() for more accurate last execution time
            let accessedAt = getAccessTime(for: url)

            return FileTimestamps(
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                accessedAt: accessedAt
            )
        } catch {
            return FileTimestamps(createdAt: nil, modifiedAt: nil, accessedAt: nil)
        }
    }

    /// Get file access time using stat() - more reliable for execution time
    private func getAccessTime(for url: URL) -> Date? {
        var statInfo = stat()
        guard stat(url.path, &statInfo) == 0 else {
            return nil
        }

        // st_atimespec is the last access time
        let accessTime = statInfo.st_atimespec
        let timeInterval = TimeInterval(accessTime.tv_sec) + TimeInterval(accessTime.tv_nsec) / 1_000_000_000
        return Date(timeIntervalSince1970: timeInterval)
    }

    /// Get timestamps for plist and binary of a persistence item
    func getItemTimestamps(plistPath: URL?, binaryPath: URL?) -> (
        plistCreated: Date?,
        plistModified: Date?,
        binaryCreated: Date?,
        binaryModified: Date?,
        binaryLastExecuted: Date?
    ) {
        var plistCreated: Date?
        var plistModified: Date?
        var binaryCreated: Date?
        var binaryModified: Date?
        var binaryLastExecuted: Date?

        if let plist = plistPath {
            let timestamps = getTimestamps(for: plist)
            plistCreated = timestamps.createdAt
            plistModified = timestamps.modifiedAt
        }

        if let binary = binaryPath {
            let timestamps = getTimestamps(for: binary)
            binaryCreated = timestamps.createdAt
            binaryModified = timestamps.modifiedAt
            binaryLastExecuted = timestamps.accessedAt
        }

        return (plistCreated, plistModified, binaryCreated, binaryModified, binaryLastExecuted)
    }

    /// Check for suspicious timestamp patterns
    func checkForSuspiciousTimestamps(item: PersistenceItem) -> [TimestampAnomaly] {
        var anomalies: [TimestampAnomaly] = []

        // Check if plist was created after we first saw it (file replaced?)
        if let created = item.plistCreatedAt,
           created > item.discoveredAt {
            anomalies.append(TimestampAnomaly(
                type: .fileReplacedAfterDiscovery,
                description: "Plist file was created AFTER we first discovered this item - possible file replacement!",
                severity: .high
            ))
        }

        // Check if binary was modified very recently (last 24h) but plist is old
        if let binaryMod = item.binaryModifiedAt,
           let plistMod = item.plistModifiedAt {
            let binaryAge = Date().timeIntervalSince(binaryMod)
            let plistAge = Date().timeIntervalSince(plistMod)

            if binaryAge < 86400 && plistAge > 86400 * 30 {
                anomalies.append(TimestampAnomaly(
                    type: .binaryRecentlyModified,
                    description: "Binary was modified in last 24h but plist is over 30 days old - possible binary swap",
                    severity: .high
                ))
            }
        }

        // Check for timestomping (creation date after modification date)
        if let created = item.binaryCreatedAt,
           let modified = item.binaryModifiedAt,
           created > modified {
            anomalies.append(TimestampAnomaly(
                type: .timestomping,
                description: "Binary creation date is AFTER modification date - possible timestomping attempt",
                severity: .critical
            ))
        }

        // Check if executed very recently but hasn't been seen running
        if let lastExec = item.binaryLastExecutedAt,
           !item.isLoaded {
            let execAge = Date().timeIntervalSince(lastExec)
            if execAge < 3600 { // Last hour
                anomalies.append(TimestampAnomaly(
                    type: .recentExecution,
                    description: "Binary was accessed in the last hour but is not currently loaded",
                    severity: .medium
                ))
            }
        }

        return anomalies
    }

    struct TimestampAnomaly: Identifiable {
        let id = UUID()
        let type: AnomalyType
        let description: String
        let severity: Severity

        enum AnomalyType: String {
            case fileReplacedAfterDiscovery = "file_replaced"
            case binaryRecentlyModified = "binary_modified"
            case timestomping = "timestomping"
            case recentExecution = "recent_execution"
        }

        enum Severity: String {
            case low = "Low"
            case medium = "Medium"
            case high = "High"
            case critical = "Critical"

            var color: String {
                switch self {
                case .low: return "blue"
                case .medium: return "yellow"
                case .high: return "orange"
                case .critical: return "red"
                }
            }
        }
    }
}
