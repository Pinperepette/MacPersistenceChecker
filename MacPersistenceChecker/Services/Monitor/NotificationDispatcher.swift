import Foundation
import UserNotifications
import AppKit

/// Handles macOS notification delivery for persistence changes
@MainActor
final class NotificationDispatcher: NSObject, ObservableObject {
    static let shared = NotificationDispatcher()

    private let center = UNUserNotificationCenter.current()

    /// Whether notification permission has been granted
    @Published private(set) var permissionGranted: Bool = false

    /// Notification category identifier
    private let categoryIdentifier = "PERSISTENCE_CHANGE"

    // MARK: - Initialization

    private override init() {
        super.init()
        center.delegate = self
        checkPermission()
        setupNotificationCategories()
    }

    // MARK: - Public Methods

    /// Request notification permission
    func requestPermission() async throws {
        NSLog("[NotificationDispatcher] Requesting notification permission...")
        let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        self.permissionGranted = granted
        NSLog("[NotificationDispatcher] Permission result: %@", granted ? "GRANTED" : "DENIED")
    }

    /// Send notification for a detected change
    func send(change: MonitorChange, relevance: Int) async {
        NSLog("[NotificationDispatcher] send() called for: %@", change.item?.name ?? "unknown")

        // Build notification content
        let title: String
        switch change.type {
        case .added: title = "New Persistence Item Detected"
        case .removed: title = "Persistence Item Removed"
        case .modified: title = "Persistence Item Modified"
        case .enabled: title = "Persistence Item Enabled"
        case .disabled: title = "Persistence Item Disabled"
        }

        var message = change.item?.name ?? "Unknown item"
        message += " [\(change.category.displayName)]"
        if let item = change.item {
            if item.trustLevel == .unsigned {
                message += " - UNSIGNED"
            } else if item.trustLevel == .suspicious {
                message += " - SUSPICIOUS"
            }
        }

        // Always show in-app alert for now (works without permissions)
        NSLog("[NotificationDispatcher] Showing alert: %@ - %@", title, message)
        showInAppAlert(title: title, message: message)
    }

    /// Show alert when system notifications fail
    private func showInAppAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Clear all pending notifications
    func clearAllNotifications() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    /// Clear badge
    func clearBadge() {
        Task {
            try? await center.setBadgeCount(0)
        }
    }

    /// Get current badge count
    func getCurrentBadgeCount() async -> Int {
        // Badge count is managed by the app
        return (try? DatabaseManager.shared.getUnacknowledgedChangeCount()) ?? 0
    }

    // MARK: - Private Methods

    private func checkPermission() {
        center.getNotificationSettings { [weak self] settings in
            let granted = settings.authorizationStatus == .authorized
            NSLog("[NotificationDispatcher] Current permission status: %@", granted ? "authorized" : "not authorized")
            DispatchQueue.main.async {
                self?.permissionGranted = granted
            }
        }
    }

    private func setupNotificationCategories() {
        let viewAction = UNNotificationAction(
            identifier: "VIEW_ACTION",
            title: "View Details",
            options: [.foreground]
        )

        let acknowledgeAction = UNNotificationAction(
            identifier: "ACKNOWLEDGE_ACTION",
            title: "Acknowledge",
            options: []
        )

        let dismissAction = UNNotificationAction(
            identifier: "DISMISS_ACTION",
            title: "Dismiss",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [viewAction, acknowledgeAction, dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        center.setNotificationCategories([category])
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationDispatcher: @preconcurrency UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show notifications even when app is in foreground
        return [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo

        guard let categoryRaw = userInfo["category"] as? String,
              let category = PersistenceCategory(rawValue: categoryRaw) else {
            return
        }

        let identifier = userInfo["identifier"] as? String
        let changeIdString = userInfo["changeId"] as? String
        let changeId = changeIdString.flatMap { UUID(uuidString: $0) }

        switch response.actionIdentifier {
        case "VIEW_ACTION", UNNotificationDefaultActionIdentifier:
            // Open app and navigate to item
            await MainActor.run {
                // Bring app to front
                NSApplication.shared.activate(ignoringOtherApps: true)

                // Select the category and item
                AppState.shared.selectedCategory = category
                if let identifier = identifier,
                   let item = AppState.shared.items.first(where: { $0.identifier == identifier }) {
                    AppState.shared.selectedItem = item
                }
            }

            // Acknowledge the change
            if let changeId = changeId {
                try? DatabaseManager.shared.acknowledgeChange(id: changeId)
            }

        case "ACKNOWLEDGE_ACTION":
            // Just acknowledge without opening
            if let changeId = changeId {
                try? DatabaseManager.shared.acknowledgeChange(id: changeId)
            }

        case "DISMISS_ACTION", UNNotificationDismissActionIdentifier:
            // Acknowledge on dismiss
            if let changeId = changeId {
                try? DatabaseManager.shared.acknowledgeChange(id: changeId)
            }

        default:
            break
        }

        // Update badge count
        await MainActor.run {
            Task {
                let count = (try? DatabaseManager.shared.getUnacknowledgedChangeCount()) ?? 0
                try? await UNUserNotificationCenter.current().setBadgeCount(count)
            }
        }
    }
}

// MARK: - Batch Notifications

extension NotificationDispatcher {
    /// Send a summary notification for multiple changes
    func sendBatchSummary(changes: [MonitorChange], detector: ChangeDetector) async {
        guard permissionGranted else { return }
        guard !changes.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "Multiple Persistence Changes Detected"
        content.subtitle = "\(changes.count) items changed"

        // Group by type
        let added = changes.filter { $0.type == .added }
        let removed = changes.filter { $0.type == .removed }
        let modified = changes.filter { $0.type == .modified || $0.type == .enabled || $0.type == .disabled }

        var bodyParts: [String] = []
        if !added.isEmpty {
            bodyParts.append("+\(added.count) new")
        }
        if !removed.isEmpty {
            bodyParts.append("-\(removed.count) removed")
        }
        if !modified.isEmpty {
            bodyParts.append("~\(modified.count) modified")
        }

        content.body = bodyParts.joined(separator: ", ")
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        // Find highest relevance
        let maxRelevance = changes.map { detector.calculateRelevance($0) }.max() ?? 0
        if MonitorConfiguration.shared.showBadge && maxRelevance >= 50 {
            let currentBadge = await getCurrentBadgeCount()
            content.badge = NSNumber(value: currentBadge + changes.count)
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            print("[NotificationDispatcher] Sent batch notification for \(changes.count) changes")
        } catch {
            print("[NotificationDispatcher] Failed to send batch notification: \(error)")
        }
    }
}
