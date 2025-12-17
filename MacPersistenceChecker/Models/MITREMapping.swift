import Foundation

/// MITRE ATT&CK Technique representation
struct MITRETechnique: Codable, Equatable, Hashable, Identifiable {
    /// Technique ID (e.g., "T1543.001")
    let id: String

    /// Technique name
    let name: String

    /// Parent technique ID if this is a sub-technique
    let parentId: String?

    /// Tactic categories
    let tactics: [MITRETactic]

    /// Brief description
    let description: String

    /// URL to MITRE ATT&CK page
    var url: URL {
        let baseId = id.replacingOccurrences(of: ".", with: "/")
        return URL(string: "https://attack.mitre.org/techniques/\(baseId)/")!
    }

    /// Display string with ID and name
    var displayName: String {
        "\(id): \(name)"
    }

    /// Short display for badges
    var shortName: String {
        id
    }
}

/// MITRE ATT&CK Tactic
enum MITRETactic: String, Codable, CaseIterable {
    case persistence = "Persistence"
    case privilegeEscalation = "Privilege Escalation"
    case defenseEvasion = "Defense Evasion"
    case execution = "Execution"
    case credentialAccess = "Credential Access"
    case discovery = "Discovery"
    case collection = "Collection"

    var color: String {
        switch self {
        case .persistence: return "purple"
        case .privilegeEscalation: return "red"
        case .defenseEvasion: return "orange"
        case .execution: return "blue"
        case .credentialAccess: return "yellow"
        case .discovery: return "green"
        case .collection: return "teal"
        }
    }
}

/// MITRE ATT&CK Mapping Database
struct MITREDatabase {

    // MARK: - Technique Definitions

    static let techniques: [String: MITRETechnique] = [
        // T1543 - Create or Modify System Process
        "T1543": MITRETechnique(
            id: "T1543",
            name: "Create or Modify System Process",
            parentId: nil,
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may create or modify system-level processes to repeatedly execute malicious payloads as part of persistence."
        ),
        "T1543.001": MITRETechnique(
            id: "T1543.001",
            name: "Launch Agent",
            parentId: "T1543",
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may create or modify Launch Agents to repeatedly execute malicious payloads as part of persistence."
        ),
        "T1543.004": MITRETechnique(
            id: "T1543.004",
            name: "Launch Daemon",
            parentId: "T1543",
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may create or modify Launch Daemons to execute malicious payloads as part of persistence."
        ),

        // T1053 - Scheduled Task/Job
        "T1053": MITRETechnique(
            id: "T1053",
            name: "Scheduled Task/Job",
            parentId: nil,
            tactics: [.execution, .persistence, .privilegeEscalation],
            description: "Adversaries may abuse task scheduling functionality to facilitate initial or recurring execution of malicious code."
        ),
        "T1053.003": MITRETechnique(
            id: "T1053.003",
            name: "Cron",
            parentId: "T1053",
            tactics: [.execution, .persistence, .privilegeEscalation],
            description: "Adversaries may abuse the cron utility to perform task scheduling for initial or recurring execution of malicious code."
        ),

        // T1546 - Event Triggered Execution
        "T1546": MITRETechnique(
            id: "T1546",
            name: "Event Triggered Execution",
            parentId: nil,
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may establish persistence using system mechanisms that trigger execution based on specific events."
        ),
        "T1546.004": MITRETechnique(
            id: "T1546.004",
            name: "Unix Shell Configuration Modification",
            parentId: "T1546",
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may establish persistence through executing malicious commands triggered by a user's shell."
        ),
        "T1546.006": MITRETechnique(
            id: "T1546.006",
            name: "LC_LOAD_DYLIB Addition",
            parentId: "T1546",
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may establish persistence by executing malicious content triggered by the execution of tainted binaries."
        ),
        "T1546.014": MITRETechnique(
            id: "T1546.014",
            name: "Emond",
            parentId: "T1546",
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may gain persistence and elevate privileges by executing malicious content triggered by the Event Monitor Daemon (emond)."
        ),
        "T1546.015": MITRETechnique(
            id: "T1546.015",
            name: "Component Object Model Hijacking",
            parentId: "T1546",
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may establish persistence by executing malicious content triggered by hijacked references to COM objects."
        ),

        // T1547 - Boot or Logon Autostart Execution
        "T1547": MITRETechnique(
            id: "T1547",
            name: "Boot or Logon Autostart Execution",
            parentId: nil,
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may configure system settings to automatically execute a program during system boot or logon."
        ),
        "T1547.006": MITRETechnique(
            id: "T1547.006",
            name: "Kernel Modules and Extensions",
            parentId: "T1547",
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may modify the kernel to automatically execute programs on system boot."
        ),
        "T1547.015": MITRETechnique(
            id: "T1547.015",
            name: "Login Items",
            parentId: "T1547",
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may add login items to execute upon user login to gain persistence or escalate privileges."
        ),

        // T1556 - Modify Authentication Process
        "T1556": MITRETechnique(
            id: "T1556",
            name: "Modify Authentication Process",
            parentId: nil,
            tactics: [.credentialAccess, .defenseEvasion, .persistence],
            description: "Adversaries may modify authentication mechanisms to access user credentials or enable otherwise unwarranted access."
        ),
        "T1556.003": MITRETechnique(
            id: "T1556.003",
            name: "Pluggable Authentication Modules",
            parentId: "T1556",
            tactics: [.credentialAccess, .defenseEvasion, .persistence],
            description: "Adversaries may modify PAM to access user credentials or enable otherwise unwarranted access to accounts."
        ),

        // T1574 - Hijack Execution Flow
        "T1574": MITRETechnique(
            id: "T1574",
            name: "Hijack Execution Flow",
            parentId: nil,
            tactics: [.persistence, .privilegeEscalation, .defenseEvasion],
            description: "Adversaries may execute their own malicious payloads by hijacking the way operating systems run programs."
        ),
        "T1574.004": MITRETechnique(
            id: "T1574.004",
            name: "Dylib Hijacking",
            parentId: "T1574",
            tactics: [.persistence, .privilegeEscalation, .defenseEvasion],
            description: "Adversaries may execute their own payloads by placing a malicious dynamic library (dylib) with an expected name in a path a victim application searches at runtime."
        ),
        "T1574.006": MITRETechnique(
            id: "T1574.006",
            name: "Dynamic Linker Hijacking",
            parentId: "T1574",
            tactics: [.persistence, .privilegeEscalation, .defenseEvasion],
            description: "Adversaries may execute their own malicious payloads by hijacking environment variables the dynamic linker uses to load shared libraries."
        ),

        // T1037 - Boot or Logon Initialization Scripts
        "T1037": MITRETechnique(
            id: "T1037",
            name: "Boot or Logon Initialization Scripts",
            parentId: nil,
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may use scripts automatically executed at boot or logon initialization to establish persistence."
        ),
        "T1037.002": MITRETechnique(
            id: "T1037.002",
            name: "Login Hook",
            parentId: "T1037",
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may use a Login Hook to establish persistence executed upon user logon."
        ),
        "T1037.004": MITRETechnique(
            id: "T1037.004",
            name: "RC Scripts",
            parentId: "T1037",
            tactics: [.persistence, .privilegeEscalation],
            description: "Adversaries may establish persistence by modifying RC scripts which are executed during a Unix-like system's startup."
        ),

        // T1059 - Command and Scripting Interpreter
        "T1059.004": MITRETechnique(
            id: "T1059.004",
            name: "Unix Shell",
            parentId: "T1059",
            tactics: [.execution],
            description: "Adversaries may abuse Unix shell commands and scripts for execution."
        ),

        // T1548 - Abuse Elevation Control Mechanism
        "T1548.004": MITRETechnique(
            id: "T1548.004",
            name: "Elevated Execution with Prompt",
            parentId: "T1548",
            tactics: [.privilegeEscalation, .defenseEvasion],
            description: "Adversaries may leverage AuthorizationExecuteWithPrivileges API to escalate privileges."
        ),

        // T1553 - Subvert Trust Controls
        "T1553.001": MITRETechnique(
            id: "T1553.001",
            name: "Gatekeeper Bypass",
            parentId: "T1553",
            tactics: [.defenseEvasion],
            description: "Adversaries may modify file attributes to evade Gatekeeper and execute unsigned or untrusted code."
        ),

        // T1564 - Hide Artifacts
        "T1564.009": MITRETechnique(
            id: "T1564.009",
            name: "Resource Forking",
            parentId: "T1564",
            tactics: [.defenseEvasion],
            description: "Adversaries may abuse resource forks to hide malicious code or executables."
        ),

        // T1569 - System Services
        "T1569.001": MITRETechnique(
            id: "T1569.001",
            name: "Launchctl",
            parentId: "T1569",
            tactics: [.execution],
            description: "Adversaries may abuse launchctl to execute commands or programs."
        ),

        // T1176 - Browser Extensions
        "T1176": MITRETechnique(
            id: "T1176",
            name: "Browser Extensions",
            parentId: nil,
            tactics: [.persistence],
            description: "Adversaries may abuse Internet browser extensions to establish persistent access to victim systems."
        ),

        // T1205 - Traffic Signaling
        "T1205.002": MITRETechnique(
            id: "T1205.002",
            name: "Socket Filters",
            parentId: "T1205",
            tactics: [.defenseEvasion, .persistence],
            description: "Adversaries may attach filters to a network socket to monitor then activate backdoors."
        ),

        // T1495 - Firmware Corruption
        "T1495": MITRETechnique(
            id: "T1495",
            name: "Firmware Corruption",
            parentId: nil,
            tactics: [.persistence],
            description: "Adversaries may overwrite or corrupt the flash memory contents of system BIOS or other firmware."
        ),

        // T1542 - Pre-OS Boot
        "T1542.003": MITRETechnique(
            id: "T1542.003",
            name: "Bootkit",
            parentId: "T1542",
            tactics: [.defenseEvasion, .persistence],
            description: "Adversaries may use bootkits to persist on systems."
        )
    ]

    // MARK: - Category to Technique Mapping

    /// Get MITRE techniques for a persistence category
    static func techniques(for category: PersistenceCategory) -> [MITRETechnique] {
        let techniqueIds: [String]

        switch category {
        case .launchDaemons:
            techniqueIds = ["T1543.004", "T1569.001"]

        case .launchAgents:
            techniqueIds = ["T1543.001", "T1569.001"]

        case .loginItems:
            techniqueIds = ["T1547.015"]

        case .kernelExtensions:
            techniqueIds = ["T1547.006"]

        case .systemExtensions:
            techniqueIds = ["T1547.006"]

        case .cronJobs:
            techniqueIds = ["T1053.003"]

        case .periodicScripts:
            techniqueIds = ["T1053.003", "T1037.004"]

        case .shellStartupFiles:
            techniqueIds = ["T1546.004", "T1059.004"]

        case .loginHooks:
            techniqueIds = ["T1037.002"]

        case .authorizationPlugins:
            techniqueIds = ["T1556.003", "T1548.004"]

        case .privilegedHelpers:
            techniqueIds = ["T1543.004", "T1548.004"]

        case .mdmProfiles:
            techniqueIds = ["T1547"] // Generic autostart

        case .spotlightImporters:
            techniqueIds = ["T1546"] // Event triggered

        case .quickLookPlugins:
            techniqueIds = ["T1546"] // Event triggered

        case .directoryServicesPlugins:
            techniqueIds = ["T1556.003"]

        case .finderSyncExtensions:
            techniqueIds = ["T1546"] // Event triggered

        case .btmDatabase:
            techniqueIds = ["T1547.015", "T1543.001"]

        case .dylibHijacking:
            techniqueIds = ["T1574.004", "T1574.006", "T1546.006"]

        case .tccAccessibility:
            techniqueIds = ["T1548.004"] // Privilege escalation

        case .applicationSupport:
            techniqueIds = ["T1176", "T1547"] // Browser extensions, autostart
        }

        return techniqueIds.compactMap { techniques[$0] }
    }

    /// Get the primary technique for a category (for badges)
    static func primaryTechnique(for category: PersistenceCategory) -> MITRETechnique? {
        techniques(for: category).first
    }

    /// Get all unique tactics for a category
    static func tactics(for category: PersistenceCategory) -> [MITRETactic] {
        let allTactics = techniques(for: category).flatMap { $0.tactics }
        return Array(Set(allTactics)).sorted { $0.rawValue < $1.rawValue }
    }

    /// Search techniques by ID or name
    static func search(_ query: String) -> [MITRETechnique] {
        let lowercaseQuery = query.lowercased()
        return techniques.values.filter { technique in
            technique.id.lowercased().contains(lowercaseQuery) ||
            technique.name.lowercased().contains(lowercaseQuery)
        }.sorted { $0.id < $1.id }
    }

    /// Get technique by ID
    static func technique(byId id: String) -> MITRETechnique? {
        techniques[id]
    }
}

// MARK: - PersistenceCategory Extension

extension PersistenceCategory {
    /// MITRE ATT&CK techniques for this category
    var mitreTechniques: [MITRETechnique] {
        MITREDatabase.techniques(for: self)
    }

    /// Primary MITRE technique ID for display
    var primaryMitreId: String? {
        MITREDatabase.primaryTechnique(for: self)?.id
    }

    /// All tactics associated with this category
    var mitreTactics: [MITRETactic] {
        MITREDatabase.tactics(for: self)
    }
}
