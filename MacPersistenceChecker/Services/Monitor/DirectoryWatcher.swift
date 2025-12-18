import Foundation
import CoreServices

/// Watches directories using FSEvents with debouncing and noise filtering
final class DirectoryWatcher {
    // MARK: - Properties

    let paths: [URL]
    let category: PersistenceCategory

    /// Callback when a relevant change is detected
    var onChange: ((DirectoryChangeEvent) -> Void)?

    private var eventStream: FSEventStreamRef?
    private let configuration: MonitorConfiguration

    // Debouncing state (per path)
    private var lastEventTimes: [String: Date] = [:]
    private var pendingEvents: [String: DispatchWorkItem] = [:]
    private let eventQueue = DispatchQueue(label: "com.mpc.directory-watcher", qos: .utility)
    private let lock = NSLock()

    /// Whether the watcher is currently active
    private(set) var isWatching: Bool = false

    // MARK: - Noise Filter Patterns

    /// File patterns to ignore
    private let noisePatterns: [String] = [
        ".DS_Store",
        ".localized",
        ".Spotlight-V100",
        ".fseventsd",
        ".Trashes",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        ".com.apple.timemachine.donotpresent"
    ]

    /// Prefixes to ignore
    private let noisePrefixes: [String] = [
        "._",           // AppleDouble files
        ".~",           // Lock files
        "~$"            // Office temp files
    ]

    /// Suffixes to ignore
    private let noiseSuffixes: [String] = [
        ".swp",         // Vim swap
        ".swo",
        ".swn",
        "~",            // Backup files
        ".tmp",
        ".temp",
        ".lock",
        ".part",        // Partial downloads
        ".crdownload",
        ".download",
        ".partial"
    ]

    /// Extensions to ignore
    private let noiseExtensions: Set<String> = [
        "log", "pid", "sock", "cache", "bak"
    ]

    // MARK: - Initialization

    init(paths: [URL], category: PersistenceCategory, configuration: MonitorConfiguration = .shared) {
        self.paths = paths
        self.category = category
        self.configuration = configuration
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Start watching directories
    func start() {
        guard eventStream == nil else {
            NSLog("[DirectoryWatcher] Already watching %@", category.displayName)
            return
        }
        NSLog("[DirectoryWatcher] Starting for %@", category.displayName)

        // Filter to existing paths only
        let existingPaths = paths.filter { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
            NSLog("[DirectoryWatcher] Path %@ exists: %d", path.path, exists ? 1 : 0)
            return exists
        }

        guard !existingPaths.isEmpty else {
            NSLog("[DirectoryWatcher] No valid paths to watch for %@", category.displayName)
            return
        }

        let pathStrings = existingPaths.map { $0.path }
        let pathsToWatch = pathStrings as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        // Use short latency for responsive monitoring
        let latency: CFTimeInterval = 0.5

        eventStream = FSEventStreamCreate(
            nil,
            { (streamRef, clientInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let clientInfo = clientInfo else { return }
                let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
                watcher.handleEvents(
                    numEvents: numEvents,
                    eventPaths: eventPaths,
                    eventFlags: eventFlags
                )
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )

        if let stream = eventStream {
            FSEventStreamSetDispatchQueue(stream, eventQueue)
            FSEventStreamStart(stream)
            isWatching = true
            print("[DirectoryWatcher] Started watching \(category.displayName): \(pathStrings.joined(separator: ", "))")
        } else {
            print("[DirectoryWatcher] Failed to create stream for \(category.displayName)")
        }
    }

    /// Stop watching directories
    func stop() {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
            isWatching = false
            print("[DirectoryWatcher] Stopped watching \(category.displayName)")
        }

        // Cancel pending debounced events
        lock.lock()
        for workItem in pendingEvents.values {
            workItem.cancel()
        }
        pendingEvents.removeAll()
        lastEventTimes.removeAll()
        lock.unlock()
    }

    // MARK: - Private Methods

    private func handleEvents(numEvents: Int, eventPaths: UnsafeMutableRawPointer, eventFlags: UnsafePointer<FSEventStreamEventFlags>) {
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
            NSLog("[DirectoryWatcher] Failed to cast event paths")
            return
        }

        NSLog("[DirectoryWatcher] Received %d events for %@", numEvents, category.displayName)

        for i in 0..<numEvents {
            let path = paths[i]
            let flags = eventFlags[i]

            NSLog("[DirectoryWatcher] Event: %@ (flags: %u)", path, flags)

            // Skip if noise
            if shouldFilterPath(path) {
                NSLog("[DirectoryWatcher] Filtered out: %@", path)
                continue
            }

            // Determine event type
            let eventType = determineEventType(flags: flags)

            // Apply cooldown/debouncing
            if shouldDebounce(path: path) {
                scheduleDebounced(path: path, eventType: eventType)
            } else {
                emitEvent(path: path, eventType: eventType)
            }
        }
    }

    private func shouldFilterPath(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent
        let lowercaseFilename = filename.lowercased()

        // Filter exact matches
        for pattern in noisePatterns {
            if filename == pattern || lowercaseFilename == pattern.lowercased() {
                return true
            }
        }

        // Filter by prefix
        for prefix in noisePrefixes {
            if filename.hasPrefix(prefix) {
                return true
            }
        }

        // Filter by suffix
        for suffix in noiseSuffixes {
            if filename.hasSuffix(suffix) || lowercaseFilename.hasSuffix(suffix.lowercased()) {
                return true
            }
        }

        // Filter by extension
        if let ext = path.split(separator: ".").last {
            let extString = String(ext).lowercased()
            if noiseExtensions.contains(extString) {
                return true
            }
        }

        // For this category, only care about relevant file types
        if !isRelevantFileForCategory(path) {
            return true
        }

        return false
    }

    private func isRelevantFileForCategory(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()

        switch category {
        case .launchDaemons, .launchAgents:
            // Only care about plist files
            return ext == "plist"

        case .kernelExtensions:
            // Kext bundles
            return ext == "kext" || path.contains(".kext/")

        case .systemExtensions:
            // System extension bundles
            return ext == "systemextension" || path.contains(".systemextension/")

        case .privilegedHelpers:
            // Executables (no extension or specific names)
            return true

        case .cronJobs:
            // Crontab files (no extension typically)
            return true

        case .shellStartupFiles:
            // Shell config files
            let shellFiles = ["zshrc", "zprofile", "zshenv", "zlogin", "zlogout",
                            "bashrc", "bash_profile", "bash_login", "bash_logout",
                            "profile"]
            return shellFiles.contains(filename) ||
                   shellFiles.contains(filename.trimmingCharacters(in: CharacterSet(charactersIn: ".")))

        case .periodicScripts:
            // Script files
            return true

        case .authorizationPlugins:
            return ext == "bundle" || path.contains(".bundle/")

        case .spotlightImporters, .quickLookPlugins:
            return ext == "mdimporter" || ext == "qlgenerator" || path.contains(".mdimporter/") || path.contains(".qlgenerator/")

        case .directoryServicesPlugins:
            return ext == "dsplug" || path.contains(".dsplug/")

        case .tccAccessibility:
            return ext == "db" || filename == "tcc.db"

        case .btmDatabase:
            return ext == "db" || filename.contains("btm")

        default:
            return true
        }
    }

    private func shouldDebounce(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let lastTime = lastEventTimes[path] else {
            return false
        }

        let cooldown = configuration.cooldownInterval
        return Date().timeIntervalSince(lastTime) < cooldown
    }

    private func scheduleDebounced(path: String, eventType: FSChangeEventType) {
        lock.lock()

        // Cancel previous pending event for this path
        pendingEvents[path]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.emitEvent(path: path, eventType: eventType)
        }

        pendingEvents[path] = workItem
        lock.unlock()

        // Execute after cooldown period
        let delay = configuration.cooldownInterval
        eventQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func emitEvent(path: String, eventType: FSChangeEventType) {
        lock.lock()
        lastEventTimes[path] = Date()
        pendingEvents.removeValue(forKey: path)
        lock.unlock()

        let event = DirectoryChangeEvent(
            path: URL(fileURLWithPath: path),
            eventType: eventType,
            category: category,
            timestamp: Date()
        )

        NSLog("[DirectoryWatcher] Change detected in %@: %@ - %@", category.displayName, eventType.rawValue, path)

        DispatchQueue.main.async { [weak self] in
            NSLog("[DirectoryWatcher] Calling onChange callback")
            self?.onChange?(event)
        }
    }

    private func determineEventType(flags: FSEventStreamEventFlags) -> FSChangeEventType {
        if flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
            return .created
        } else if flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
            return .deleted
        } else if flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
            return .modified
        } else if flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
            return .renamed
        }
        return .modified
    }
}

// MARK: - DirectoryWatcher Manager

/// Manages multiple DirectoryWatchers
final class DirectoryWatcherManager {
    private var watchers: [PersistenceCategory: DirectoryWatcher] = [:]
    private let lock = NSLock()

    /// Callback when any watcher detects a change
    var onChangeDetected: ((DirectoryChangeEvent) -> Void)?

    /// Start watching a category
    func startWatching(category: PersistenceCategory, configuration: MonitorConfiguration = .shared) {
        lock.lock()
        defer { lock.unlock() }

        guard watchers[category] == nil else {
            print("[WatcherManager] Already watching \(category.displayName)")
            return
        }

        let paths = category.monitoredPaths.filter { url in
            FileManager.default.fileExists(atPath: url.path)
        }

        guard !paths.isEmpty else {
            print("[WatcherManager] No paths to watch for \(category.displayName)")
            return
        }

        let watcher = DirectoryWatcher(paths: paths, category: category, configuration: configuration)
        watcher.onChange = { [weak self] event in
            self?.onChangeDetected?(event)
        }
        watcher.start()

        watchers[category] = watcher
    }

    /// Stop watching a category
    func stopWatching(category: PersistenceCategory) {
        lock.lock()
        defer { lock.unlock() }

        watchers[category]?.stop()
        watchers.removeValue(forKey: category)
    }

    /// Stop all watchers
    func stopAll() {
        lock.lock()
        defer { lock.unlock() }

        for watcher in watchers.values {
            watcher.stop()
        }
        watchers.removeAll()
    }

    /// Check if watching a specific category
    func isWatching(category: PersistenceCategory) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return watchers[category]?.isWatching ?? false
    }

    /// Get all currently watched categories
    var watchedCategories: Set<PersistenceCategory> {
        lock.lock()
        defer { lock.unlock() }
        return Set(watchers.keys)
    }
}
