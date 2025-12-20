# MacPersistenceChecker

**Show me what stays, explain why it matters, let me decide.**

A native macOS security tool that enumerates everything configured to run automatically on your Mac. Find malware, unwanted software, or understand what's really running on your system.

## Download

**[Download MacPersistenceChecker v1.8.1 (DMG)](https://github.com/Pinperepette/MacPersistenceChecker/releases/download/v1.8.1/MacPersistenceChecker.dmg)**

- Requires macOS 13.0 or later
- Universal binary (Apple Silicon & Intel)
- If macOS says the app is damaged: `xattr -cr /Applications/MacPersistenceChecker.app`

## What It Does

MacPersistenceChecker scans every persistence mechanism on macOS, analyzes each item for risk, and gives you the information to decide what should stay and what should go.

---

## Persistence Scanning

### Core Scanners
- **Launch Daemons** - System-wide services (`/Library/LaunchDaemons`, `/System/Library/LaunchDaemons`)
- **Launch Agents** - User-level agents (`~/Library/LaunchAgents`, `/Library/LaunchAgents`)
- **Login Items** - Apps that start at login
- **Kernel Extensions** - Legacy kexts
- **System Extensions** - Modern system extensions (DriverKit, NetworkExtension, EndpointSecurity)
- **Privileged Helper Tools** - XPC services with elevated privileges
- **Cron Jobs** - Scheduled tasks
- **Configuration Profiles** - MDM and configuration profiles
- **Application Support** - Background apps and helpers

### Extended Scanners (optional)
- **Periodic Scripts** - Daily, weekly, monthly scripts in `/etc/periodic/`
- **Shell Startup Files** - `.zshrc`, `.bashrc`, `/etc/profile` with suspicious pattern detection
- **Login/Logout Hooks** - Legacy login hooks via `com.apple.loginwindow`
- **Authorization Plugins** - Security Agent plugins in `/Library/Security/SecurityAgentPlugins`
- **Spotlight Importers** - Custom metadata importers
- **Quick Look Plugins** - Preview generators that could be abused
- **Directory Services Plugins** - Authentication plugins
- **Finder Sync Extensions** - Finder extensions via pluginkit
- **BTM Database** - Background Task Management entries (macOS 13+)
- **Dylib Hijacking** - Detection of `DYLD_INSERT_LIBRARIES` and suspicious dylib injection
- **TCC/Accessibility** - Apps with Accessibility permissions in TCC database

---

## Risk Assessment

Every persistence item gets a **Risk Score (0-100)** based on multiple factors:

- Invalid or missing code signatures
- Missing hardened runtime protection
- Ad-hoc signed binaries
- Suspicious file locations
- Persistent auto-start configurations (RunAtLoad, KeepAlive)
- Known malware patterns

**Severity Levels:** Low, Medium, High, Critical - items sorted by risk for quick threat identification.

### Launch Frequency Anomaly Detection
- **Micro-Restart** - StartInterval < 60 seconds (possible watchdog abuse)
- **Aggressive Watchdog** - KeepAlive + low StartInterval combination
- **No Throttle Limit** - KeepAlive without ThrottleInterval (crash-restart loop risk)

### Signed-but-Dangerous Detection
- **Dangerous Entitlements** - Detection of risky entitlements (`com.apple.security.cs.disable-library-validation`, etc.)
- **Apple Impersonation** - Non-Apple software trying to appear as Apple
- **Hidden Locations** - Signed apps in suspicious directories
- **Notarization Gaps** - Recent apps lacking notarization
- **Developer Certificate Analysis** - Team ID validation against known vendors

### LOLBins Detection (Living-off-the-Land Binaries)
Detects suspicious use of legitimate macOS binaries in persistence contexts. **The combo matters:**

- **osascript + persistence** = AppleScript with auto-start (GUI automation abuse)
- **curl/wget + RunAtLoad** = Download & execute pattern
- **python + privileged helper** = Elevated script execution
- **security + KeepAlive** = Credential harvesting risk
- **launchctl + auto-start** = Meta-persistence installer
- **netcat + persistence** = Reverse shell / C2 channel

40+ LOLBins tracked with MITRE ATT&CK mappings and context-aware severity scoring.

### Binary Reputation & Behavioral Analysis
Advanced heuristics to detect suspicious behavioral patterns:

- **Hidden Persistence Guard** - KeepAlive agent without obvious watchdog purpose
- **Aggressive Persistence** - RunAtLoad + KeepAlive on non-service items
- **Stealthy Auto-Start** - Background process from unknown vendor
- **Orphaned Persistence** - Plist points to non-existent executable
- **Suspicious Location** - Executable in `/tmp/`, `/Users/Shared/`, or hidden directories
- **Privilege Escalation Risk** - User agent attempting privileged operations
- **Network-Enabled Persistence** - Persistence with network capabilities
- **Script-Based Persistence** - Inline scripts via interpreters
- **System Process Impersonation** - Non-Apple item using Apple-like naming
- **Frequent Restart Pattern** - StartInterval < 60 seconds

### Plist vs Binary Intent Mismatch
Detects when what the plist declares doesn't match what the binary actually does - **exactly what modern droppers do:**

- **Innocent Plist, Heavy Binary** - Simple config but binary has dangerous entitlements
- **Passive Helper with Network** - Background helper with network client/server access
- **Passive Helper with Dylib Loading** - Helper that can load unsigned code
- **Minimal Config, Maximum Capabilities** - Minimal plist but extensive entitlements
- **Simple Task with Keychain Access** - Simple-looking task with credential access

### Binary Age vs Persistence Age
Detects suspicious timestamp patterns that indicate post-install malicious updates:

- **Old Plist, New Binary** - Classic "malicious update post-install" pattern
- **Silent Binary Swap** - Binary modified without plist change
- **Timestamp Manipulation** - Modification date before creation date (impossible)
- **Suspicious Modification Time** - Binary modified at 2-5 AM
- **Binary Modified After Install** - Non-updater binary changed after initial install

### Trust Levels
- 🟢 **Apple** - Signed by Apple
- 🔵 **Known Vendor** - Verified third-party software
- 🟡 **Signed** - Valid signature but not notarized
- ⚪ **Unknown** - No executable to verify
- 🟠 **Suspicious** - Expired certificate or suspicious path
- 🔴 **Unsigned** - No valid signature

---

## Timeline & Forensics

Comprehensive forensic timeline for each persistence item:

**Discovery**
- First Seen - When the item was first discovered

**Configuration File (Plist)**
- Created - File creation timestamp
- Modified - Last modification timestamp

**Executable (Binary)**
- Created - Binary creation timestamp
- Modified - Last modification timestamp
- Last Executed - Last access/execution time

### Timestamp Anomaly Detection
- **Timestomping** - Creation date after modification date (anti-forensics technique)
- **File Replacement** - File created after initial discovery
- **Binary Swap** - Recently modified binary with old plist (possible trojan)
- **Recent Execution** - Binary accessed recently but not currently loaded

---

## MITRE ATT&CK Integration

Every persistence mechanism mapped to MITRE ATT&CK framework:

- **Tactics**: Persistence, Privilege Escalation, Defense Evasion, Execution
- **Techniques**: T1543.001, T1543.004, T1547.001, T1547.015, and more
- Direct links to MITRE ATT&CK documentation

---

## App Invasiveness Report

Comprehensive analysis of installed apps to evaluate their "invasiveness" level:

### Dual Scoring System

**Persistence Score (0-100)** - Evaluates persistence mechanisms:
- Trigger types (RunAtLoad, KeepAlive)
- Privilege levels (LaunchDaemons, Kernel Extensions, Privileged Helpers)
- Resilience (auto-restart, updaters)
- Redundancy (multiple items from same vendor)
- Trust level (unsigned/suspicious penalties)

**Installation Score (0-100)** - Evaluates "junk" footprint:
- File spread across Library folders
- Total disk usage
- Orphan files (persistence without matching app)
- Cache bloat
- System-wide installations

### Grade System
Apps rated **A through F** based on combined score with detailed breakdown of all scoring factors.

---

## Visualization

### Statistics Dashboard
- **Risk Distribution Histogram** - Items by risk bands (Low, Medium, High, Critical)
- **Trust Level Donut Chart** - Distribution across trust levels
- **Category Breakdown Chart** - Items per persistence category
- **Timeline Visualization** - Item lifecycle events (Created, Modified, Executed, Discovered)

### Interactive Graph
- **Full System Graph** - Overview of all persistence items and relationships
- **Focused Item Graph** - Radial graph for individual item analysis
- **Analysis Modes**: Basic (trust/categories) or Full (includes dylib dependencies, network connections)
- **Interactive Canvas** - Zoom, pan, explore relationships
- **Color-coded by trust level** - Quick visual threat assessment

### Security Profile Radar
Comprehensive radar chart showing Trust, Signature, Safety, Stability, Transparency, and Age dimensions at a glance.

---

## Real-time Monitoring

Continuous monitoring of persistence changes with two analysis modes.

### Monitoring Modes

**Standard Mode**
- FSEvents-based real-time file system monitoring
- Intelligent noise suppression with configurable debounce
- Relevance scoring to filter insignificant changes
- Immediate notifications for high-relevance changes

**AI Mode** (requires Claude API key)
- Claude AI analyzes each detected change
- Full context sent to AI: signature info, LOLBins, behavioral anomalies, risk scores
- AI decides if change warrants notification based on actual threat level
- Configurable check interval (30s to 1 hour)
- Severity threshold filtering (Info, Low, Medium, High, Critical)

### Menu Bar Integration
- Real-time monitoring status indicator
- Mode badge showing "AI" or "Std"
- Quick controls (Start/Stop monitoring, trigger scan)
- Settings access
- Badge count for unacknowledged changes
- Last detected change preview

### Notification Deduplication
- Same item won't trigger repeated notifications within cooldown period
- Configurable cooldown (1-24 hours, default 2 hours)
- Prevents notification fatigue from frequently-changing items

### Startup Notification
When monitoring starts, you receive a notification confirming:
- Active mode (AI Mode or Standard Mode)
- Check interval (AI) or "Real-time" (Standard)
- Notification threshold settings

### Change Detection
- **Added** - New persistence items
- **Removed** - Deleted items
- **Modified** - Configuration changes (enabled/disabled, path changes, etc.)
- **Enabled/Disabled** - State changes

### AI Analysis Details
When AI mode is active, each change sends complete item data to Claude:
- Basic info (name, category, paths, plist content)
- Signature details (signed, Apple, notarized, team ID, certificate status)
- Risk assessment (score, detailed breakdown)
- LOLBins detections with MITRE mappings
- Behavioral anomalies
- Intent mismatches (plist vs binary)
- Age anomalies (timestamp analysis)
- Signed-but-dangerous flags

Claude responds with:
- `shouldNotify` - Whether to alert the user
- `severity` - Threat level assessment
- `title` - Notification title
- `explanation` - Why this is or isn't suspicious
- `recommendation` - Suggested action
- `mitreTechniques` - Relevant ATT&CK techniques

### AI Customization

Control how the AI analyzes changes via **Settings → AI**:

**Structured Options**
| Option | Default | Effect |
|--------|---------|--------|
| Ignore Apple-signed | ON | Deprioritize items signed by Apple (com.apple.*) |
| Ignore system paths | ON | Deprioritize /System and /Library paths |
| Prioritize unsigned | ON | Extra attention to unsigned executables |
| Focus on LOLBins | ON | Prioritize Living-off-the-Land Binaries detection |
| Minimum risk score | 0 | Only analyze items with risk >= threshold |
| Ignored paths | - | Custom paths to skip (comma-separated) |

**Notification Threshold**
- `Info` - Notify everything
- `Low` - Notify low severity and above
- `Medium` - Notify medium and above (default)
- `High` - Only high and critical
- `Critical` - Only critical threats

**Custom Prompt**
Add your own instructions that are appended to the AI prompt. Examples:
```
Always notify me if an item uses python or osascript.
Ignore anything from Microsoft.
Be more aggressive with unsigned items from ~/Downloads.
```

The AI uses these preferences to make smarter decisions. For example:
- Unsigned LaunchAgent from `/tmp/` → **Critical notification**
- Signed Dropbox update → **No notification (info)**
- `osascript` with `RunAtLoad` → **High notification**

---

## MCP Server (Claude Code Integration)

MacPersistenceChecker includes an MCP (Model Context Protocol) server that allows Claude Code, Claude Desktop, and other MCP-compatible clients to query persistence data.

### Building the MCP Server

```bash
swift build --target MPCServer
```

The binary is created at `.build/debug/mpc-server`.

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `get_current_state` | Get all current persistence items with optional filters |
| `get_diff` | Get changes from baseline or specific snapshot |
| `get_summary` | Compact overview with counts and top threats |
| `get_item_details` | Full details for a specific item by identifier |
| `get_risk_analysis` | Aggregated risk analysis with recommendations |
| `get_snapshots` | List available snapshots with metadata |
| `compare_snapshots` | Compare two snapshots for changes |

### Claude Code Configuration

Add to your Claude Code MCP settings (`~/.claude/claude_desktop_config.json` or similar):

```json
{
  "mcpServers": {
    "macpersistence": {
      "command": "/path/to/mpc-server",
      "args": []
    }
  }
}
```

### Example Queries

Once configured, you can ask Claude Code:
- "What persistence items are on this Mac?"
- "Show me unsigned items with high risk scores"
- "What changed since the last snapshot?"
- "Analyze the risk of items in the LaunchAgents category"
- "Compare today's snapshot with yesterday's"

### MCP Server Features
- Read-only access to MacPersistenceChecker's SQLite database
- JSON-RPC 2.0 protocol over stdio
- Filters by category, trust level, risk score, Apple-signed status
- Full snapshot and diff capabilities
- No separate API key required (uses local database)

---

## Snapshots & Comparison

- Create snapshots of your system state
- Compare snapshots to detect changes over time
- Track new, removed, or modified persistence items
- Identify when suspicious items were added

---

## Forensic JSON Export

Machine-readable export for security pipelines:

- **SIEM Integration** - Ingestible by Splunk, Elastic, etc.
- **SOAR Compatibility** - Ready for automated response workflows
- **LLM Analysis** - Structured data for AI-powered analysis
- **IR Pipelines** - Compatible with OSINT and incident response tools

### Export Contents
- Full system metadata (hostname, macOS version, hardware model, serial)
- All persistence items with complete analysis
- Risk scores, LOLBins, behavioral anomalies, intent mismatches, age analysis
- MITRE ATT&CK mappings
- Complete forensic timeline with Unix timestamps
- Critical findings with recommendations

**Button enabled only after scan completion.**

---

## Containment System

Safely neutralize suspicious persistence items without permanent deletion:

### Containment Actions
- **Quick Contain** - Disable persistence + block network (recommended)
- **Disable Only** - Remove from auto-start without network block
- **Network Block Only** - Block network access while keeping persistence active

### Safety Features
- **Automatic Backup** - Original plist saved before any modification
- **Timed Release** - Auto-restore after configurable timeout (default 24h)
- **Manual Release** - Instantly restore contained items
- **Action Log** - Complete audit trail of all containment actions

### Network Blocking
- PF firewall rules to block outbound connections
- Per-binary blocking by executable path
- Survives app restart

### Use Cases
- Quarantine suspicious item while investigating
- Test if removing persistence breaks functionality
- Temporarily disable without losing configuration

---

## Actions

- **Reveal in Finder** - Quickly locate files
- **Open Plist** - View configuration files
- **View Graph** - Per-item graph visualization
- **Disable/Enable** - Safely disable items (with admin privileges for system items)
- **Contain** - Quarantine suspicious items with automatic backup
- **Export JSON** - Export forensic report for SIEM/SOAR/IR

---

## Screenshots

![Main View](imm/1.png)

![Item Details](imm/9.png)

![Snapshot Comparison](imm/3.png)

![Snapshot Comparison](imm/4.png)

![Extended Scanners](imm/6.png)

![Extended Scanners Settings](imm/5.png)

![App Invasiveness](imm/7.png)

![Menu Bar](imm/8.png)

---

## Building from Source

```bash
git clone https://github.com/Pinperepette/MacPersistenceChecker.git
cd MacPersistenceChecker
./build.sh
```

Copy `MacPersistenceChecker.app` to `/Applications/`.

### Requirements
- macOS 13.0+
- Xcode 15+ or Swift 5.9+

### Dependencies
- [GRDB.swift](https://github.com/groue/GRDB.swift) - SQLite database

---

## Permissions

Requires **Full Disk Access** to scan:
- `/Library/LaunchDaemons`
- System configuration files
- TCC database
- Shell startup files

Without Full Disk Access, some items may not be visible.

---

## License

MIT License - See [LICENSE](LICENSE) for details.

## Author

**pinperepette** - 2025

---

*Inspired by [Autoruns](https://docs.microsoft.com/en-us/sysinternals/downloads/autoruns) for Windows by Mark Russinovich*
