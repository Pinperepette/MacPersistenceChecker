import Foundation
import SwiftUI

/// Categorie di meccanismi di persistenza macOS
enum PersistenceCategory: String, CaseIterable, Identifiable, Codable {
    case launchDaemons = "launch_daemons"
    case launchAgents = "launch_agents"
    case loginItems = "login_items"
    case kernelExtensions = "kernel_extensions"
    case systemExtensions = "system_extensions"
    case privilegedHelpers = "privileged_helpers"
    case cronJobs = "cron_jobs"
    case mdmProfiles = "mdm_profiles"
    case applicationSupport = "application_support"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .launchDaemons: return "Launch Daemons"
        case .launchAgents: return "Launch Agents"
        case .loginItems: return "Login Items"
        case .kernelExtensions: return "Kernel Extensions"
        case .systemExtensions: return "System Extensions"
        case .privilegedHelpers: return "Privileged Helpers"
        case .cronJobs: return "Cron Jobs"
        case .mdmProfiles: return "MDM Profiles"
        case .applicationSupport: return "Application Support"
        }
    }

    var systemImage: String {
        switch self {
        case .launchDaemons: return "gearshape.2"
        case .launchAgents: return "person.crop.circle.badge.clock"
        case .loginItems: return "person.badge.key"
        case .kernelExtensions: return "cpu"
        case .systemExtensions: return "puzzlepiece.extension"
        case .privilegedHelpers: return "lock.shield"
        case .cronJobs: return "clock.arrow.circlepath"
        case .mdmProfiles: return "building.2"
        case .applicationSupport: return "folder.badge.questionmark"
        }
    }

    var description: String {
        switch self {
        case .launchDaemons:
            return "System-level services that run as root, regardless of user login"
        case .launchAgents:
            return "User-level services that run when a user logs in"
        case .loginItems:
            return "Applications and helpers that launch at user login"
        case .kernelExtensions:
            return "Legacy kernel extensions (kexts) that extend kernel functionality"
        case .systemExtensions:
            return "Modern user-space extensions (network, endpoint security, driver)"
        case .privilegedHelpers:
            return "Helper tools that run with elevated privileges"
        case .cronJobs:
            return "Scheduled tasks using the cron daemon"
        case .mdmProfiles:
            return "Mobile Device Management configuration profiles"
        case .applicationSupport:
            return "Potentially suspicious items in Application Support folders"
        }
    }

    /// Paths monitored by this category
    var monitoredPaths: [URL] {
        switch self {
        case .launchDaemons:
            return [
                URL(fileURLWithPath: "/Library/LaunchDaemons"),
                URL(fileURLWithPath: "/System/Library/LaunchDaemons")
            ]
        case .launchAgents:
            return [
                URL(fileURLWithPath: "/Library/LaunchAgents"),
                URL(fileURLWithPath: "/System/Library/LaunchAgents"),
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/LaunchAgents")
            ]
        case .loginItems:
            return [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/com.apple.backgroundtaskmanagementagent")
            ]
        case .kernelExtensions:
            return [
                URL(fileURLWithPath: "/Library/Extensions"),
                URL(fileURLWithPath: "/System/Library/Extensions")
            ]
        case .systemExtensions:
            return [
                URL(fileURLWithPath: "/Library/SystemExtensions")
            ]
        case .privilegedHelpers:
            return [
                URL(fileURLWithPath: "/Library/PrivilegedHelperTools")
            ]
        case .cronJobs:
            return [
                URL(fileURLWithPath: "/var/at/tabs"),
                URL(fileURLWithPath: "/usr/lib/cron/tabs")
            ]
        case .mdmProfiles:
            return [] // MDM profiles are queried via profiles command
        case .applicationSupport:
            return [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support")
            ]
        }
    }

    /// Whether this category requires Full Disk Access
    var requiresFullDiskAccess: Bool {
        switch self {
        case .launchDaemons, .kernelExtensions, .cronJobs:
            return true
        default:
            return false
        }
    }
}
