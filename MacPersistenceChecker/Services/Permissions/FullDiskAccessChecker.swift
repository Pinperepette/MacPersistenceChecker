import Foundation
import Combine
import AppKit

/// Verifica e monitora Full Disk Access
final class FullDiskAccessChecker: ObservableObject {
    /// Shared instance
    static let shared = FullDiskAccessChecker()

    /// Whether the app has Full Disk Access
    @Published private(set) var hasFullDiskAccess: Bool = false

    /// Whether we're actively checking for access
    @Published private(set) var isChecking: Bool = false

    private var checkTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Initial check
        hasFullDiskAccess = checkAccess()
    }

    /// Check if the app has Full Disk Access
    @discardableResult
    func checkAccess() -> Bool {
        // Method 1: Try to read the TCC database (requires FDA)
        let tccPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        if canReadFile(at: tccPath) {
            hasFullDiskAccess = true
            return true
        }

        // Method 2: Try to read Safari history (requires FDA)
        let safariHistory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/History.db")
            .path
        if canReadFile(at: safariHistory) {
            hasFullDiskAccess = true
            return true
        }

        // Method 3: Try to read Mail data (requires FDA)
        let mailPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail")
            .path
        if canListDirectory(at: mailPath) {
            hasFullDiskAccess = true
            return true
        }

        // Method 4: Check if we can read /Library/LaunchDaemons fully
        // Some items there require FDA
        let launchDaemonsPath = "/Library/LaunchDaemons"
        if canListDirectory(at: launchDaemonsPath) {
            // Additional check: try to read a specific protected plist
            let testPath = "/Library/Application Support/com.apple.TCC/TCC.db"
            if FileManager.default.isReadableFile(atPath: testPath) {
                hasFullDiskAccess = true
                return true
            }
        }

        hasFullDiskAccess = false
        return false
    }

    /// Start polling for FDA status (useful during onboarding)
    func startPolling(interval: TimeInterval = 2.0, onGranted: (() -> Void)? = nil) {
        stopPolling()
        isChecking = true

        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            if self.checkAccess() {
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

    private func canReadFile(at path: String) -> Bool {
        let fileHandle = open(path, O_RDONLY)
        if fileHandle != -1 {
            close(fileHandle)
            return true
        }
        return false
    }

    private func canListDirectory(at path: String) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return true
        } catch {
            return false
        }
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
