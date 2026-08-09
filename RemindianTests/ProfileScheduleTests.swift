import XCTest
@testable import Remindian

/// Auto-sync is per profile: the timer ticks at the shortest enabled interval and
/// each tick syncs only the profiles whose own interval has elapsed.
@MainActor
final class ProfileScheduleTests: XCTestCase {

    private func profile(_ name: String, autoSync: Bool = true, minutes: Int = 5, enabled: Bool = true) -> SyncProfile {
        let config = SyncConfiguration()
        config.enableAutoSync = autoSync
        config.syncIntervalMinutes = minutes
        return SyncProfile(name: name, enabled: enabled, config: config)
    }

    private func minutesAgo(_ minutes: Int) -> Date {
        Date().addingTimeInterval(-Double(minutes) * 60)
    }

    // MARK: - Clamping (inherited from the #80 overflow class)

    func test_intervalIsClamped() {
        XCTAssertEqual(SyncManager.clampedIntervalMinutes(0), 1, "0 would fire continuously")
        XCTAssertEqual(SyncManager.clampedIntervalMinutes(-5), 1)
        XCTAssertEqual(SyncManager.clampedIntervalMinutes(15), 15)
        XCTAssertEqual(SyncManager.clampedIntervalMinutes(999_999), 24 * 60, "Must not overflow minutes * 60")
    }

    // MARK: - Due calculation

    func test_profileNeverRunIsDue() {
        let p = profile("Work")
        let due = SyncManager.profilesDue([p], lastRun: [:], now: Date())
        XCTAssertEqual(due.map(\.name), ["Work"], "A profile that has never run must sync on the first tick")
    }

    func test_profileWithinItsIntervalIsNotDue() {
        let p = profile("Work", minutes: 30)
        let due = SyncManager.profilesDue([p], lastRun: [p.id: minutesAgo(5)], now: Date())
        XCTAssertTrue(due.isEmpty, "Only 5 of 30 minutes elapsed")
    }

    func test_profilePastItsIntervalIsDue() {
        let p = profile("Work", minutes: 15)
        let due = SyncManager.profilesDue([p], lastRun: [p.id: minutesAgo(20)], now: Date())
        XCTAssertEqual(due.map(\.name), ["Work"])
    }

    /// The point of the feature: different cadences coexist on one timer.
    func test_onlyTheDueProfileSyncs() {
        let fast = profile("Work", minutes: 5)
        let slow = profile("Personal", minutes: 60)
        let lastRun = [fast.id: minutesAgo(10), slow.id: minutesAgo(10)]
        let due = SyncManager.profilesDue([fast, slow], lastRun: lastRun, now: Date())
        XCTAssertEqual(due.map(\.name), ["Work"], "The hourly profile isn't due after 10 minutes")
    }

    func test_profileWithAutoSyncOffIsNeverDue() {
        let manual = profile("Manual", autoSync: false)
        XCTAssertTrue(SyncManager.profilesDue([manual], lastRun: [:], now: Date()).isEmpty)
    }

    func test_dueExactlyOnTheBoundary() {
        let p = profile("Work", minutes: 10)
        let due = SyncManager.profilesDue([p], lastRun: [p.id: minutesAgo(10)], now: Date())
        XCTAssertEqual(due.count, 1, "Elapsed == interval counts as due")
    }

    // MARK: - Backwards compatibility

    /// Existing installs have identical intervals on every profile (they used to be
    /// forced equal), so upgrading must not change when anything syncs.
    func test_identicalIntervalsBehaveLikeBefore() {
        let a = profile("A", minutes: 15)
        let b = profile("B", minutes: 15)
        let lastRun = [a.id: minutesAgo(20), b.id: minutesAgo(20)]
        let due = SyncManager.profilesDue([a, b], lastRun: lastRun, now: Date())
        XCTAssertEqual(Set(due.map(\.name)), ["A", "B"], "Both due together, exactly as a single shared timer behaved")
    }

    func test_scheduleIsNoLongerPropagatedBetweenProfiles() {
        // applyGlobalSettings copies app-wide settings only; the schedule stays local.
        let active = SyncConfiguration()
        active.enableAutoSync = true
        active.syncIntervalMinutes = 5
        active.enableNotifications = true

        let other = SyncConfiguration()
        other.enableAutoSync = false
        other.syncIntervalMinutes = 60
        other.enableNotifications = false

        other.applyGlobalSettings(from: active)

        XCTAssertEqual(other.syncIntervalMinutes, 60, "Interval must stay per profile")
        XCTAssertFalse(other.enableAutoSync, "Auto-sync toggle must stay per profile")
        XCTAssertTrue(other.enableNotifications, "App-wide settings are still propagated")
    }
}
