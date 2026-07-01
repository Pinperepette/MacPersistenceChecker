import Foundation
import Combine
import AppKit
import Darwin

enum FDAProbeAPI: String {
    case posixOpen
    case contentsOfDirectory
    case isReadableFile
}

enum FDAProbeID: String, CaseIterable {
    case systemTCCDatabase
    case userSafariHistory
    case userMailDirectory
    case launchDaemonsDirectory
    case launchDaemonsTCCDatabaseReadable

    var contributesToGrant: Bool {
        switch self {
        case .launchDaemonsDirectory:
            return false
        case .systemTCCDatabase, .userSafariHistory, .userMailDirectory, .launchDaemonsTCCDatabaseReadable:
            return true
        }
    }
}

enum FDAAccessRefreshReason: String {
    case startup
    case previousGrantValidation
    case manual
    case polling
    case appBecameActive
    case sceneBecameActive
}

struct FDAProbeResult {
    let probeID: FDAProbeID
    let path: String
    let api: FDAProbeAPI
    let success: Bool
    let errnoCode: Int32?
    let cocoaErrorDomain: String?
    let cocoaErrorCode: Int?
    let timestamp: Date

    init(
        probeID: FDAProbeID,
        path: String,
        api: FDAProbeAPI,
        success: Bool,
        errnoCode: Int32? = nil,
        cocoaErrorDomain: String? = nil,
        cocoaErrorCode: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.probeID = probeID
        self.path = path
        self.api = api
        self.success = success
        self.errnoCode = errnoCode
        self.cocoaErrorDomain = cocoaErrorDomain
        self.cocoaErrorCode = cocoaErrorCode
        self.timestamp = timestamp
    }

    var diagnosticSummary: String {
        var parts = [
            "\(probeID.rawValue)",
            "api=\(api.rawValue)",
            "success=\(success)"
        ]

        if let errnoCode {
            parts.append("errno=\(errnoCode)")
        }

        if let cocoaErrorDomain, let cocoaErrorCode {
            parts.append("cocoa=\(cocoaErrorDomain)(\(cocoaErrorCode))")
        }

        return parts.joined(separator: " ")
    }
}

struct FDAAccessSnapshot {
    let reason: FDAAccessRefreshReason
    let results: [FDAProbeResult]
    let timestamp: Date

    var isGranted: Bool {
        results.contains { result in
            result.success && result.probeID.contributesToGrant
        }
    }

    var diagnosticSummary: String {
        let probeSummaries = results
            .map(\.diagnosticSummary)
            .joined(separator: "; ")
        return "reason=\(reason.rawValue) granted=\(isGranted) probes=[\(probeSummaries)]"
    }
}

protocol FDAProbeExecuting {
    func canOpenForRead(probeID: FDAProbeID, path: String) -> FDAProbeResult
    func canListDirectory(probeID: FDAProbeID, path: String) -> FDAProbeResult
    func isReadableFile(probeID: FDAProbeID, path: String) -> FDAProbeResult
}

struct DefaultFDAProbeExecutor: FDAProbeExecuting {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func canOpenForRead(probeID: FDAProbeID, path: String) -> FDAProbeResult {
        Darwin.errno = 0
        let fileHandle = Darwin.open(path, O_RDONLY)

        if fileHandle != -1 {
            Darwin.close(fileHandle)
            return FDAProbeResult(
                probeID: probeID,
                path: path,
                api: .posixOpen,
                success: true
            )
        }

        return FDAProbeResult(
            probeID: probeID,
            path: path,
            api: .posixOpen,
            success: false,
            errnoCode: Darwin.errno
        )
    }

    func canListDirectory(probeID: FDAProbeID, path: String) -> FDAProbeResult {
        do {
            _ = try fileManager.contentsOfDirectory(atPath: path)
            return FDAProbeResult(
                probeID: probeID,
                path: path,
                api: .contentsOfDirectory,
                success: true
            )
        } catch let error as NSError {
            return FDAProbeResult(
                probeID: probeID,
                path: path,
                api: .contentsOfDirectory,
                success: false,
                cocoaErrorDomain: error.domain,
                cocoaErrorCode: error.code
            )
        }
    }

    func isReadableFile(probeID: FDAProbeID, path: String) -> FDAProbeResult {
        if fileManager.isReadableFile(atPath: path) {
            return FDAProbeResult(
                probeID: probeID,
                path: path,
                api: .isReadableFile,
                success: true
            )
        }

        let cocoaError = readabilityFailure(forPath: path)
        return FDAProbeResult(
            probeID: probeID,
            path: path,
            api: .isReadableFile,
            success: false,
            cocoaErrorDomain: cocoaError.domain,
            cocoaErrorCode: cocoaError.code
        )
    }

    private func readabilityFailure(forPath path: String) -> NSError {
        do {
            _ = try fileManager.attributesOfItem(atPath: path)
            return NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        } catch let error as NSError {
            return error
        }
    }
}

/// Verifica e monitora Full Disk Access
final class FullDiskAccessChecker: ObservableObject {
    /// Shared instance
    static let shared = FullDiskAccessChecker()

    /// Whether the app has Full Disk Access
    @Published private(set) var hasFullDiskAccess: Bool = false

    /// Whether we're actively checking for access
    @Published private(set) var isChecking: Bool = false

    /// Most recent structured FDA probe evidence.
    @Published private(set) var lastSnapshot: FDAAccessSnapshot?

    /// Key for persisting FDA granted status
    private let fdaGrantedKey = "fdaWasGranted"

    private let executor: FDAProbeExecuting
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var checkTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(
        executor: FDAProbeExecuting = DefaultFDAProbeExecutor(),
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        observeAppActivation: Bool = true,
        performInitialCheck: Bool = true
    ) {
        self.executor = executor
        self.defaults = defaults
        self.notificationCenter = notificationCenter

        if observeAppActivation {
            registerAppActivationRefresh()
        }

        if performInitialCheck {
            initializeAccessState()
        }
    }

    /// Check if the app has Full Disk Access (and persist if granted)
    @discardableResult
    func checkAccess() -> Bool {
        refreshAccess(reason: .manual).isGranted
    }

    /// Refresh FDA state and keep the persisted fast-path key in sync.
    @discardableResult
    func refreshAccess(reason: FDAAccessRefreshReason) -> FDAAccessSnapshot {
        let wasPreviouslyGranted = defaults.bool(forKey: fdaGrantedKey)
        let snapshot = performAccessCheck(reason: reason)

        lastSnapshot = snapshot
        hasFullDiskAccess = snapshot.isGranted

        if snapshot.isGranted {
            defaults.set(true, forKey: fdaGrantedKey)
        } else if wasPreviouslyGranted {
            defaults.set(false, forKey: fdaGrantedKey)
        }

        NSLog("[FDA] %@", snapshot.diagnosticSummary)
        return snapshot
    }

    /// Start polling for FDA status (useful during onboarding)
    func startPolling(interval: TimeInterval = 2.0, onGranted: (() -> Void)? = nil) {
        stopPolling()
        isChecking = true

        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }

            let snapshot = self.refreshAccess(reason: .polling)
            if snapshot.isGranted {
                self.stopPolling()
                onGranted?()
            }
        }
    }

    /// Stop polling
    func stopPolling() {
        checkTimer?.invalidate()
        checkTimer = nil
        isChecking = false
    }

    /// Open System Settings to the Full Disk Access pane
    func openSystemSettings() {
        // macOS Ventura and later use different URL scheme
        if #available(macOS 13.0, *) {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
            NSWorkspace.shared.open(url)
        } else {
            // Older macOS
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings directly (alternative method)
    func openPrivacySettings() {
        let script = """
            tell application "System Settings"
                activate
                reveal anchor "Privacy_AllFiles" of pane id "com.apple.preference.security"
            end tell
            """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
        }

        // Fallback to URL scheme if AppleScript fails
        if error != nil {
            openSystemSettings()
        }
    }

    // MARK: - Private Helpers

    private func initializeAccessState() {
        if defaults.bool(forKey: fdaGrantedKey) {
            let snapshot = refreshAccess(reason: .previousGrantValidation)
            if snapshot.isGranted {
                return
            }
        }

        _ = refreshAccess(reason: .startup)
    }

    private func registerAppActivationRefresh() {
        notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                _ = self?.refreshAccess(reason: .appBecameActive)
            }
            .store(in: &cancellables)
    }

    /// Perform the actual FDA check without mutating checker state.
    private func performAccessCheck(reason: FDAAccessRefreshReason) -> FDAAccessSnapshot {
        let tccPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        let safariHistory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/History.db")
            .path
        let mailPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail")
            .path
        let launchDaemonsPath = "/Library/LaunchDaemons"

        let results = [
            executor.canOpenForRead(probeID: .systemTCCDatabase, path: tccPath),
            executor.canOpenForRead(probeID: .userSafariHistory, path: safariHistory),
            executor.canListDirectory(probeID: .userMailDirectory, path: mailPath),
            executor.canListDirectory(probeID: .launchDaemonsDirectory, path: launchDaemonsPath),
            executor.isReadableFile(probeID: .launchDaemonsTCCDatabaseReadable, path: tccPath)
        ]

        return FDAAccessSnapshot(
            reason: reason,
            results: results,
            timestamp: Date()
        )
    }
}

// MARK: - Permission Status

extension FullDiskAccessChecker {
    /// Overall permission status
    enum PermissionStatus {
        case granted
        case denied
        case unknown

        var description: String {
            switch self {
            case .granted:
                return "Full Disk Access granted"
            case .denied:
                return "Full Disk Access required"
            case .unknown:
                return "Checking permissions..."
            }
        }
    }

    var status: PermissionStatus {
        if hasFullDiskAccess {
            return .granted
        } else if isChecking {
            return .unknown
        } else {
            return .denied
        }
    }
}
