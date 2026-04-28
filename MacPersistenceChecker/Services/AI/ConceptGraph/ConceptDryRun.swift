import Foundation

/// Runs the concept extraction pipeline over a list of items WITHOUT
/// persisting anything, and writes a human-readable dump to:
///   ~/Library/Logs/MacPersistenceChecker/concepts_dryrun.txt
///
/// This is the gate for Milestone 1: we want to see — on real data — how many
/// concepts emerge, how items distribute across them, and whether the
/// extraction makes sense before committing the rest of the pipeline.
enum ConceptDryRun {

    static var dumpURL: URL {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MacPersistenceChecker", isDirectory: true)
            .appendingPathComponent("concepts_dryrun.txt")
    }

    /// Runs extraction on the given items and writes the dump to disk.
    /// Returns the URL of the dump file.
    @discardableResult
    static func run(items: [PersistenceItem]) -> URL {
        let pipeline = ConceptExtractionPipeline.shared
        let started = Date()

        // Per-concept aggregation.
        struct Bucket {
            var displayName: String
            var kind: ConceptKind
            var items: [(String, String)] = []   // (item.name, signal)
        }
        var buckets: [String: Bucket] = [:]
        var perItemConceptCounts: [Int] = []
        var emptyItems: [PersistenceItem] = []

        for item in items {
            let signals = pipeline.extract(from: item)
            perItemConceptCounts.append(signals.count)
            if signals.isEmpty { emptyItems.append(item) }
            for signal in signals {
                if buckets[signal.conceptID] == nil {
                    buckets[signal.conceptID] = Bucket(
                        displayName: signal.displayName,
                        kind: signal.kind
                    )
                }
                buckets[signal.conceptID]?.items.append((item.name, signal.signal))
            }
        }

        // Cluster signature aggregation (sorted concept-IDs hashed).
        var clusterCounts: [String: Int] = [:]
        var clusterExamples: [String: String] = [:]
        for item in items {
            let ids = pipeline.extract(from: item).map(\.conceptID).sorted()
            let key = ids.joined(separator: ",")
            clusterCounts[key, default: 0] += 1
            if clusterExamples[key] == nil { clusterExamples[key] = item.name }
        }

        let elapsed = Date().timeIntervalSince(started)

        // Build dump.
        var out = "==== CONCEPT EXTRACTION DRY-RUN ====\n"
        out += "Generated: \(ISO8601DateFormatter().string(from: started))\n"
        out += "Items processed: \(items.count)\n"
        out += "Pipeline version: \(pipeline.version)\n"
        out += "Elapsed: \(String(format: "%.2f", elapsed))s\n\n"

        out += "── Concept-per-item distribution ──\n"
        out += "average: \(String(format: "%.2f", avg(perItemConceptCounts)))\n"
        out += "min: \(perItemConceptCounts.min() ?? 0), max: \(perItemConceptCounts.max() ?? 0)\n"
        out += "items with 0 concepts: \(emptyItems.count)\n\n"

        out += "── Concepts (\(buckets.count) total) ──\n"
        let sorted = buckets.sorted { $0.value.items.count > $1.value.items.count }
        for (id, bucket) in sorted {
            out += "[\(bucket.kind.rawValue)] \(id) — \(bucket.displayName)\n"
            out += "    items: \(bucket.items.count)\n"
            for (name, signal) in bucket.items.prefix(3) {
                out += "      • \(name)  (\(signal))\n"
            }
            if bucket.items.count > 3 {
                out += "      … +\(bucket.items.count - 3) more\n"
            }
            out += "\n"
        }

        out += "── Concept signature clusters (\(clusterCounts.count) total) ──\n"
        let sortedClusters = clusterCounts.sorted { $0.value > $1.value }
        for (sig, count) in sortedClusters {
            let display = sig.isEmpty ? "(empty signature)" : sig
            out += "[\(count) items] \(display)\n"
            if let example = clusterExamples[sig] {
                out += "    example: \(example)\n"
            }
        }
        out += "\n"

        if !emptyItems.isEmpty {
            out += "── Items with NO concept signals (first 20) ──\n"
            for item in emptyItems.prefix(20) {
                out += "  • \(item.name)  [\(item.category.rawValue)]  \(item.executablePath?.path ?? "-")\n"
            }
            out += "\n"
        }

        // Write to disk.
        let url = dumpURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func avg(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
}
