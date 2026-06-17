import Foundation

/// Crash-loop breaker. (#80)
///
/// If a launch crashes during startup — before the app has had a chance to mark
/// itself healthy — the *next* launch enters **Safe Mode**: every *automatic*
/// sync trigger (launch sync, interval timer, file watcher, agenda scan, pinned
/// window restore) is suppressed so the app always opens. The user leaves Safe
/// Mode explicitly from the menu bar; a clean run is never mistaken for a crash.
///
/// The state lives in `UserDefaults` so it survives a process kill:
///   - `launchPending` — set at the very start of launch, cleared once the app
///     proves it survived startup (timer backstop + clean termination). If it's
///     still set at the next launch, the previous launch crashed during startup.
///   - `active` — sticky. Latched on when a startup crash is detected; only the
///     user's explicit Resume clears it. This is why a deterministic launch crash
///     can't ping-pong: once in Safe Mode we stay there until told otherwise.
enum SafeMode {
    private static let pendingKey = "safeMode.launchPending"
    private static let activeKey = "safeMode.active"

    /// Injection seam for tests; production reads/writes `.standard`.
    static var defaults: UserDefaults = .standard

    /// Whether automatic sync is currently suppressed after a startup crash.
    static var isActive: Bool { defaults.bool(forKey: activeKey) }

    /// Call once at the very start of `applicationWillFinishLaunching`, before any
    /// automatic work is scheduled or `SyncManager` reads its state. If a prior
    /// launch left `launchPending` set (it crashed before `markHealthy`), latch
    /// Safe Mode on. Returns the resulting `isActive`.
    @discardableResult
    static func registerLaunchAttempt() -> Bool {
        if defaults.bool(forKey: pendingKey) {
            defaults.set(true, forKey: activeKey)   // previous startup crashed
        }
        defaults.set(true, forKey: pendingKey)
        // Force the flag to disk now: the crash we're guarding against can strike
        // seconds from here, before UserDefaults' periodic flush would run.
        defaults.synchronize()
        return isActive
    }

    /// The app survived startup (or is terminating cleanly). Clear `launchPending`
    /// so a clean run is never read as a crash. Deliberately leaves the sticky
    /// `active` flag untouched — only `resume()` clears that.
    static func markHealthy() {
        defaults.set(false, forKey: pendingKey)
        defaults.synchronize()
    }

    /// User chose to leave Safe Mode. Clear both flags so this session and the
    /// next launch behave normally.
    static func resume() {
        defaults.set(false, forKey: activeKey)
        defaults.set(false, forKey: pendingKey)
        defaults.synchronize()
    }
}
