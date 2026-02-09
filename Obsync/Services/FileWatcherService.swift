import Foundation

/// Watches an Obsidian vault directory for file changes using FSEvents.
/// Triggers a callback when markdown files are modified, created, or deleted.
/// Debounces rapid changes to avoid excessive sync triggers.
class FileWatcherService {
    static let shared = FileWatcherService()

    private var streamRef: FSEventStreamRef?
    private var debounceTimer: Timer?
    private var watchedPath: String?
    private var onChange: (() -> Void)?

    /// Debounce interval: wait this long after the last change before triggering sync
    private let debounceInterval: TimeInterval = 2.0

    private init() {}

    /// Start watching a vault directory for markdown file changes.
    /// - Parameters:
    ///   - path: The vault root path to watch
    ///   - onChange: Callback fired when relevant files change (debounced)
    func startWatching(path: String, onChange: @escaping () -> Void) {
        // Stop any existing watcher
        stopWatching()

        guard FileManager.default.fileExists(atPath: path) else {
            debugLog("[FileWatcher] Path does not exist: \(path)")
            return
        }

        self.watchedPath = path
        self.onChange = onChange

        let pathsToWatch = [path] as CFArray
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagUseCFTypes) |
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // Latency in seconds
            flags
        ) else {
            debugLog("[FileWatcher] Failed to create FSEvent stream")
            return
        }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)

        debugLog("[FileWatcher] Started watching: \(path)")
    }

    /// Stop watching for file changes.
    func stopWatching() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
            debugLog("[FileWatcher] Stopped watching: \(watchedPath ?? "unknown")")
        }
        debounceTimer?.invalidate()
        debounceTimer = nil
        watchedPath = nil
        onChange = nil
    }

    /// Called by the FSEvents callback when changes are detected.
    fileprivate func handleFileSystemEvent(paths: [String]) {
        // Filter: only care about markdown files
        let relevantChanges = paths.filter { path in
            let lower = path.lowercased()
            // Must be a markdown file
            guard lower.hasSuffix(".md") else { return false }
            // Ignore hidden files and common non-content directories
            let components = path.components(separatedBy: "/")
            for component in components {
                if component.hasPrefix(".") || component == "node_modules" {
                    return false
                }
            }
            return true
        }

        guard !relevantChanges.isEmpty else { return }

        debugLog("[FileWatcher] Detected \(relevantChanges.count) markdown file change(s)")

        // Debounce: reset timer on each event, only trigger after quiet period
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.debounceTimer?.invalidate()
            self.debounceTimer = Timer.scheduledTimer(withTimeInterval: self.debounceInterval, repeats: false) { [weak self] _ in
                debugLog("[FileWatcher] Debounce complete, triggering sync")
                self?.onChange?()
            }
        }
    }

    var isWatching: Bool {
        return streamRef != nil
    }
}

// MARK: - FSEvents C Callback

private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FileWatcherService>.fromOpaque(info).takeUnretainedValue()

    // Extract paths from the CFArray
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

    watcher.handleFileSystemEvent(paths: paths)
}
