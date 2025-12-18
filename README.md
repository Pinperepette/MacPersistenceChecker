# MacPersistenceChecker

**Show me what stays, explain why it matters, let me decide.**

A native macOS security tool that enumerates everything configured to run automatically on your Mac. Find malware, unwanted software, or understand what's really running on your system.

## Download

**[Download MacPersistenceChecker v1.8 (DMG)](https://github.com/Pinperepette/MacPersistenceChecker/releases/download/v1.8/MacPersistenceChecker.dmg)**

- Requires macOS 13.0 or later
- Universal binary (Apple Silicon & Intel)
- If macOS says the app is damaged: `xattr -cr /Applications/MacPersistenceChecker.app`

## What It Does

MacPersistenceChecker scans every persistence mechanism on macOS, analyzes each item for risk, and gives you the information to decide what should stay and what should go.

### Complete Persistence Scanning

**Core Scanners:**
- Launch Daemons & Agents
- Login Items
- Kernel & System Extensions
- Privileged Helper Tools
- Cron Jobs
- MDM Profiles
- Application Support helpers

**Extended Scanners** (optional):
- Periodic Scripts
- Shell Startup Files (`.zshrc`, `.bashrc`, etc.)
- Login/Logout Hooks
- Authorization Plugins
- Spotlight Importers & Quick Look Plugins
- Directory Services Plugins
- Finder Sync Extensions
- BTM Database (macOS 13+)
- Dylib Hijacking detection
- TCC/Accessibility permissions

### Risk Analysis

Every item gets a **Risk Score (0-100)** based on:
- Code signature validity
- Hardened runtime protection
- File locations
- Launch frequency patterns (micro-restart, aggressive watchdog)
- Known malware patterns
- MITRE ATT&CK mapping

**Trust Levels:**
- 🟢 Apple signed
- 🔵 Known vendor
- 🟡 Signed (not notarized)
- 🟠 Suspicious
- 🔴 Unsigned

### Forensic Timeline

For each item:
- First discovery date
- Plist creation/modification
- Binary creation/modification/last execution
- Timestamp anomaly detection (timestomping, binary swap)

### Visualization

- **Statistics Dashboard** - Risk distribution, trust levels, category breakdown
- **Interactive Graph** - Visualize relationships between persistence items
- **Security Profile Radar** - Trust, signature, safety dimensions at a glance

### Real-time Monitoring

- Menu bar integration
- FSEvents-based change detection
- Notifications for new persistence items

### Actions

- Reveal in Finder
- Open Plist
- Disable/Enable items
- Create snapshots for comparison over time

## Screenshots

![Main View](imm/1.png)

![Item Details](imm/9.png)

![Snapshot Comparison](imm/3.png)

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
- [GRDB.swift](https://github.com/groue/GRDB.swift)

## Permissions

Requires **Full Disk Access** to scan:
- `/Library/LaunchDaemons`
- System configuration files
- TCC database
- Shell startup files

## License

MIT License - See [LICENSE](LICENSE) for details.

## Author

**pinperepette** - 2025

---

*Inspired by [Autoruns](https://docs.microsoft.com/en-us/sysinternals/downloads/autoruns) for Windows*
