import Foundation

/// Protocollo base per tutti gli scanner di persistenza
protocol PersistenceScanner {
    /// Categoria di persistenza gestita
    var category: PersistenceCategory { get }

    /// Path monitorati da questo scanner
    var monitoredPaths: [URL] { get }

    /// Se lo scanner richiede Full Disk Access
    var requiresFullDiskAccess: Bool { get }

    /// Esegue la scansione e ritorna gli item trovati
    func scan() async throws -> [PersistenceItem]
}

/// Errori degli scanner
enum ScannerError: Error, LocalizedError {
    case accessDenied(String)
    case invalidPlist(String)
    case parseError(String)
    case executionError(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let path):
            return "Access denied to \(path)"
        case .invalidPlist(let path):
            return "Invalid plist at \(path)"
        case .parseError(let msg):
            return "Parse error: \(msg)"
        case .executionError(let msg):
            return "Execution error: \(msg)"
        }
    }
}

/// Orchestratore di tutti gli scanner
@MainActor
final class ScannerOrchestrator: ObservableObject {
    /// All registered scanners (core + extended)
    private let allScanners: [PersistenceScanner]

    /// Scanner configuration
    private let configuration: ScannerConfiguration

    /// Trust verifier for signature checking
    private let trustVerifier: TrustVerifier

    /// Current scanning state
    @Published var isScanning: Bool = false

    /// Overall progress (0.0 - 1.0)
    @Published var progress: Double = 0

    /// Currently scanning category
    @Published var currentCategory: PersistenceCategory?

    /// Last error encountered
    @Published var lastError: Error?

    /// Scan statistics
    @Published var scanStats: ScanStatistics = ScanStatistics()

    /// Currently enabled scanners based on configuration
    var scanners: [PersistenceScanner] {
        allScanners.filter { configuration.isEnabled($0.category) }
    }

    init(trustVerifier: TrustVerifier = TrustVerifier(), configuration: ScannerConfiguration = .shared) {
        self.trustVerifier = trustVerifier
        self.configuration = configuration

        // Core Scanners (always available)
        var scannerList: [PersistenceScanner] = [
            LaunchDaemonScanner(),
            LaunchAgentScanner(),
            LoginItemScanner(),
            KextScanner(),
            SystemExtensionScanner(),
            PrivilegedHelperScanner(),
            CronJobScanner(),
            MDMProfileScanner(),
            ApplicationSupportScanner()
        ]

        // Extended Scanners (optional)
        let extendedScanners: [PersistenceScanner] = [
            PeriodicScriptsScanner(),
            ShellStartupScanner(),
            LoginHooksScanner(),
            AuthorizationPluginsScanner(),
            SpotlightImportersScanner(),
            QuickLookPluginsScanner(),
            DirectoryServicesPluginsScanner(),
            FinderSyncExtensionsScanner(),
            BTMDatabaseScanner(),
            DylibHijackingScanner(),
            TCCAccessibilityScanner()
        ]

        scannerList.append(contentsOf: extendedScanners)
        self.allScanners = scannerList
    }

    /// Scan all categories - with progress updates
    func scanAll() async -> [PersistenceItem] {
        isScanning = true
        progress = 0
        lastError = nil
        scanStats = ScanStatistics()

        defer {
            isScanning = false
            currentCategory = nil
        }

        let totalScanners = Double(scanners.count)
        var completedScanners = 0
        var allItems: [PersistenceItem] = []

        // Run scanners with progress tracking (each scanner runs off main actor)
        for scanner in scanners {
            currentCategory = scanner.category

            // Run scanner off main actor to prevent blocking
            let result: (items: [PersistenceItem], error: Error?) = await Task.detached {
                do {
                    let items = try await scanner.scan()
                    return (items, nil)
                } catch {
                    return ([], error)
                }
            }.value

            if let error = result.error {
                print("Scanner \(scanner.category.displayName) failed: \(error)")
                lastError = error
                scanStats.errors.append(ScanError(category: scanner.category, error: error))
            } else {
                scanStats.categoryCounts[scanner.category] = result.items.count
                allItems.append(contentsOf: result.items)
            }

            completedScanners += 1
            progress = Double(completedScanners) / totalScanners * 0.5
        }

        progress = 0.5 // Scanning done, now verifying
        currentCategory = nil

        // PHASE 2: Verify trust with progress
        let verifiedItems = await verifyItemsFast(allItems)

        progress = 1.0
        scanStats.totalItems = verifiedItems.count
        scanStats.completedAt = Date()

        return verifiedItems
    }

    /// Fast verification - skip obvious Apple items, parallel for the rest
    private func verifyItemsFast(_ items: [PersistenceItem]) async -> [PersistenceItem] {
        // Split items: obvious Apple vs needs verification
        var appleItems: [PersistenceItem] = []
        var needsVerification: [PersistenceItem] = []

        for item in items {
            if isObviouslyApple(item) {
                var appleItem = item
                appleItem.trustLevel = .apple
                appleItem.signatureInfo = SignatureInfo(
                    isSigned: true,
                    isValid: true,
                    isAppleSigned: true,
                    isNotarized: true,
                    hasHardenedRuntime: true,
                    teamIdentifier: nil,
                    bundleIdentifier: item.bundleIdentifier,
                    commonName: "Apple",
                    organizationName: "Apple Inc.",
                    certificateExpirationDate: nil,
                    isCertificateExpired: false,
                    signingAuthority: "Apple Root CA",
                    codeDirectoryHash: nil,
                    flags: nil
                )
                appleItems.append(appleItem)
            } else {
                needsVerification.append(item)
            }
        }

        // Verify non-Apple items off main actor
        let verifier = trustVerifier
        let verified = await Task.detached {
            var results: [PersistenceItem] = []
            for item in needsVerification {
                let verifiedItem = await verifier.verify(item)
                results.append(verifiedItem)
            }
            return results
        }.value

        return appleItems + verified
    }

    /// Check if item is obviously from Apple (skip expensive verification)
    private func isObviouslyApple(_ item: PersistenceItem) -> Bool {
        // Check identifier
        if item.identifier.hasPrefix("com.apple.") {
            return true
        }

        // Check paths
        let applePaths = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/"]
        if let path = item.executablePath?.path {
            for applePath in applePaths {
                if path.hasPrefix(applePath) {
                    return true
                }
            }
        }
        if let path = item.plistPath?.path {
            if path.hasPrefix("/System/Library/") {
                return true
            }
        }

        return false
    }

    /// Scan a specific category
    func scan(category: PersistenceCategory) async -> [PersistenceItem] {
        guard let scanner = scanners.first(where: { $0.category == category }) else {
            return []
        }

        isScanning = true
        currentCategory = category
        defer {
            isScanning = false
            currentCategory = nil
        }

        do {
            let items = try await scanner.scan()
            return await verifyItems(items)
        } catch {
            lastError = error
            return []
        }
    }

    /// Verify trust for a batch of items
    private func verifyItems(_ items: [PersistenceItem]) async -> [PersistenceItem] {
        await withTaskGroup(of: PersistenceItem.self) { group in
            for item in items {
                group.addTask {
                    await self.trustVerifier.verify(item)
                }
            }

            var results: [PersistenceItem] = []
            for await item in group {
                results.append(item)
            }
            return results
        }
    }

    /// Check if any scanner requires FDA and we don't have it
    var requiresFullDiskAccess: Bool {
        let fdaChecker = FullDiskAccessChecker.shared
        if fdaChecker.hasFullDiskAccess {
            return false
        }
        return scanners.contains { $0.requiresFullDiskAccess }
    }

    /// Get scanners that require FDA
    var scannersRequiringFDA: [PersistenceScanner] {
        scanners.filter { $0.requiresFullDiskAccess }
    }

    /// Get all available scanners (including disabled ones)
    var availableScanners: [PersistenceScanner] {
        allScanners
    }

    /// Get extended scanners that are currently enabled
    var enabledExtendedScanners: [PersistenceScanner] {
        allScanners.filter { $0.category.isExtendedScanner && configuration.isEnabled($0.category) }
    }

    /// Get count of enabled extended scanners
    var enabledExtendedCount: Int {
        enabledExtendedScanners.count
    }

    /// Total available extended scanners
    var totalExtendedCount: Int {
        allScanners.filter { $0.category.isExtendedScanner }.count
    }
}

// MARK: - Supporting Types

struct ScanStatistics {
    var totalItems: Int = 0
    var categoryCounts: [PersistenceCategory: Int] = [:]
    var categoryTimes: [PersistenceCategory: TimeInterval] = [:]
    var errors: [ScanError] = []
    var startedAt: Date = Date()
    var completedAt: Date?

    var duration: TimeInterval {
        (completedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var hasErrors: Bool {
        !errors.isEmpty
    }
}

struct ScanError: Identifiable {
    let id = UUID()
    let category: PersistenceCategory
    let error: Error
}
