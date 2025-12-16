# MacPersistenceChecker

**Autoruns for macOS** - Enumerate, analyze and control every persistence mechanism on your system.

A native macOS security tool that shows you everything configured to run automatically on your Mac. Find malware, unwanted software, or just understand what's running on your system.

## Download

**[Download MacPersistenceChecker v1.0 (DMG)](https://github.com/Pinperepette/MacPersistenceChecker/releases/download/v1.0/MacPersistenceChecker.dmg)**

- Requires macOS 13.0 or later
- Universal binary (Apple Silicon & Intel)

## Features

### Complete Persistence Enumeration
- **Launch Daemons** - System-wide services (`/Library/LaunchDaemons`, `/System/Library/LaunchDaemons`)
- **Launch Agents** - User-level agents (`~/Library/LaunchAgents`, `/Library/LaunchAgents`)
- **Login Items** - Apps that start at login
- **Kernel Extensions** - Legacy kexts
- **System Extensions** - Modern system extensions (DriverKit, NetworkExtension, EndpointSecurity)
- **Privileged Helper Tools** - XPC services with elevated privileges
- **Cron Jobs** - Scheduled tasks
- **Configuration Profiles** - MDM and configuration profiles
- **Application Support** - Background apps and helpers

### Trust Verification
- **Code Signature Verification** - Validates signatures using Security.framework
- **Notarization Check** - Verifies Apple notarization status
- **Known Vendor Database** - Identifies trusted software vendors
- **Color-coded Trust Levels**:
  - 🟢 **Apple** - Signed by Apple
  - 🔵 **Known Vendor** - Verified third-party software
  - 🟡 **Signed** - Valid signature but not notarized
  - ⚪ **Unknown** - No executable to verify
  - 🟠 **Suspicious** - Expired certificate or suspicious path
  - 🔴 **Unsigned** - No valid signature

### Timeline & Snapshots
- Create snapshots of your system state
- Compare snapshots to detect changes over time
- Track new, removed, or modified persistence items
- Identify when suspicious items were added

### Control Actions
- **Reveal in Finder** - Quickly locate files
- **Open Plist** - View configuration files
- **Disable/Enable** - Safely disable items (with admin privileges for system items)

## Screenshots

*Coming soon*

## Building from Source

### Requirements
- macOS 13.0+
- Xcode 15+ or Swift 5.9+

### Build

```bash
git clone https://github.com/Pinperepette/MacPersistenceChecker.git
cd MacPersistenceChecker
swift build -c release
```

The executable will be in `.build/release/MacPersistenceChecker`.

### Dependencies
- [GRDB.swift](https://github.com/groue/GRDB.swift) - SQLite database

## Usage

1. Launch the app
2. Grant Full Disk Access when prompted (required to scan all persistence locations)
3. Click "Scan" to enumerate all persistence mechanisms
4. Review items - suspicious items are highlighted
5. Use "Snapshot" to save the current state for future comparison

## Permissions

MacPersistenceChecker requires **Full Disk Access** to read:
- `/Library/LaunchDaemons`
- System configuration files
- TCC database

Without Full Disk Access, some items may not be visible.

## License

MIT License - See [LICENSE](LICENSE) for details.

## Author

**pinperepette**

---

*Inspired by [Autoruns](https://docs.microsoft.com/en-us/sysinternals/downloads/autoruns) for Windows by Mark Russinovich*
