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

    // MARK: - Extended Persistence Vectors
    case periodicScripts = "periodic_scripts"
    case shellStartupFiles = "shell_startup_files"
    case loginHooks = "login_hooks"
    case authorizationPlugins = "authorization_plugins"
    case spotlightImporters = "spotlight_importers"
    case quickLookPlugins = "quicklook_plugins"
    case directoryServicesPlugins = "directory_services_plugins"
    case finderSyncExtensions = "finder_sync_extensions"
    case btmDatabase = "btm_database"
    case dylibHijacking = "dylib_hijacking"
    case tccAccessibility = "tcc_accessibility"

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
        // Extended vectors
        case .periodicScripts: return "Periodic Scripts"
        case .shellStartupFiles: return "Shell Startup Files"
        case .loginHooks: return "Login/Logout Hooks"
        case .authorizationPlugins: return "Authorization Plugins"
        case .spotlightImporters: return "Spotlight Importers"
        case .quickLookPlugins: return "Quick Look Plugins"
        case .directoryServicesPlugins: return "Directory Services Plugins"
        case .finderSyncExtensions: return "Finder Sync Extensions"
        case .btmDatabase: return "BTM Database"
        case .dylibHijacking: return "Dylib Hijacking"
        case .tccAccessibility: return "TCC/Accessibility"
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
        // Extended vectors
        case .periodicScripts: return "calendar.badge.clock"
        case .shellStartupFiles: return "terminal"
        case .loginHooks: return "arrow.right.circle"
        case .authorizationPlugins: return "person.badge.shield.checkmark"
        case .spotlightImporters: return "magnifyingglass"
        case .quickLookPlugins: return "eye"
        case .directoryServicesPlugins: return "folder.badge.gearshape"
        case .finderSyncExtensions: return "arrow.triangle.2.circlepath"
        case .btmDatabase: return "cylinder.split.1x2"
        case .dylibHijacking: return "link.badge.plus"
        case .tccAccessibility: return "hand.raised"
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
        // Extended vectors
        case .periodicScripts:
            return "Scripts executed periodically by launchd (daily, weekly, monthly)"
        case .shellStartupFiles:
            return "Shell configuration files executed on login or shell startup"
        case .loginHooks:
            return "Legacy login/logout hooks configured via loginwindow"
        case .authorizationPlugins:
            return "Plugins loaded by the authorization framework"
        case .spotlightImporters:
            return "Plugins used by Spotlight for indexing files"
        case .quickLookPlugins:
            return "Plugins used by Quick Look for previewing files"
        case .directoryServicesPlugins:
            return "Plugins for Directory Services (LDAP, AD, etc.)"
        case .finderSyncExtensions:
            return "Extensions that sync with Finder (Dropbox, iCloud, etc.)"
        case .btmDatabase:
            return "Background Task Management database (macOS 13+)"
        case .dylibHijacking:
            return "Environment variables and paths for dylib injection"
        case .tccAccessibility:
            return "Apps with accessibility and TCC permissions"
        }
    }

    /// Paths monitored by this category
    var monitoredPaths: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
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
                home.appendingPathComponent("Library/LaunchAgents")
            ]
        case .loginItems:
            return [
                home.appendingPathComponent("Library/Application Support/com.apple.backgroundtaskmanagementagent")
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
                home.appendingPathComponent("Library/Application Support")
            ]
        // Extended vectors
        case .periodicScripts:
            return [
                URL(fileURLWithPath: "/etc/periodic/daily"),
                URL(fileURLWithPath: "/etc/periodic/weekly"),
                URL(fileURLWithPath: "/etc/periodic/monthly"),
                URL(fileURLWithPath: "/usr/local/etc/periodic/daily"),
                URL(fileURLWithPath: "/usr/local/etc/periodic/weekly"),
                URL(fileURLWithPath: "/usr/local/etc/periodic/monthly")
            ]
        case .shellStartupFiles:
            return [
                // User shell files
                home.appendingPathComponent(".zshrc"),
                home.appendingPathComponent(".zprofile"),
                home.appendingPathComponent(".zshenv"),
                home.appendingPathComponent(".zlogin"),
                home.appendingPathComponent(".bashrc"),
                home.appendingPathComponent(".bash_profile"),
                home.appendingPathComponent(".profile"),
                // System shell files
                URL(fileURLWithPath: "/etc/zshrc"),
                URL(fileURLWithPath: "/etc/zprofile"),
                URL(fileURLWithPath: "/etc/profile"),
                URL(fileURLWithPath: "/etc/bashrc")
            ]
        case .loginHooks:
            return [] // Queried via defaults command
        case .authorizationPlugins:
            return [
                URL(fileURLWithPath: "/Library/Security/SecurityAgentPlugins")
            ]
        case .spotlightImporters:
            return [
                URL(fileURLWithPath: "/Library/Spotlight"),
                home.appendingPathComponent("Library/Spotlight")
            ]
        case .quickLookPlugins:
            return [
                URL(fileURLWithPath: "/Library/QuickLook"),
                home.appendingPathComponent("Library/QuickLook")
            ]
        case .directoryServicesPlugins:
            return [
                URL(fileURLWithPath: "/Library/DirectoryServices/PlugIns")
            ]
        case .finderSyncExtensions:
            return [] // Queried via pluginkit command
        case .btmDatabase:
            return [
                URL(fileURLWithPath: "/private/var/db/com.apple.backgroundtaskmanagement")
            ]
        case .dylibHijacking:
            return [] // Checked via environment and system queries
        case .tccAccessibility:
            return [
                URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC"),
                home.appendingPathComponent("Library/Application Support/com.apple.TCC")
            ]
        }
    }

    /// Whether this category requires Full Disk Access
    var requiresFullDiskAccess: Bool {
        switch self {
        case .launchDaemons, .kernelExtensions, .cronJobs:
            return true
        case .btmDatabase, .tccAccessibility, .directoryServicesPlugins:
            return true
        case .shellStartupFiles:
            return true // For /etc/ files
        default:
            return false
        }
    }

    /// Whether this is an extended/optional scanner
    var isExtendedScanner: Bool {
        switch self {
        case .periodicScripts, .shellStartupFiles, .loginHooks, .authorizationPlugins,
             .spotlightImporters, .quickLookPlugins, .directoryServicesPlugins,
             .finderSyncExtensions, .btmDatabase, .dylibHijacking, .tccAccessibility:
            return true
        default:
            return false
        }
    }

    /// Core categories (always enabled)
    static var coreCategories: [PersistenceCategory] {
        allCases.filter { !$0.isExtendedScanner }
    }

    /// Extended categories (optionally enabled)
    static var extendedCategories: [PersistenceCategory] {
        allCases.filter { $0.isExtendedScanner }
    }
}
