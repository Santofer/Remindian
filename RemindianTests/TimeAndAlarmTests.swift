import XCTest
@testable import Remindian

/// Tests for due-time parsing and reminder alarm computation (#6, v5.20.0).
final class TimeAndAlarmTests: XCTestCase {

    private let cal = Calendar.current

    private func comps(_ date: Date?) -> DateComponents? {
        date.map { cal.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
    }

    // MARK: - Obsidian due-time parsing

    func test_dueDate_withSpaceTime() {
        let task = SyncTask.fromObsidianLine("- [ ] Standup 📅 2026-03-15 14:30", filePath: "/n.md", lineNumber: 1)
        let c = comps(task?.dueDate)
        XCTAssertEqual(c?.year, 2026); XCTAssertEqual(c?.month, 3); XCTAssertEqual(c?.day, 15)
        XCTAssertEqual(c?.hour, 14); XCTAssertEqual(c?.minute, 30)
        XCTAssertEqual(task?.title, "Standup", "Date+time must be stripped from the title.")
    }

    func test_dueDate_withTTime() {
        let task = SyncTask.fromObsidianLine("- [ ] Call 📅 2026-03-15T09:05", filePath: "/n.md", lineNumber: 1)
        let c = comps(task?.dueDate)
        XCTAssertEqual(c?.hour, 9); XCTAssertEqual(c?.minute, 5)
    }

    func test_dueDate_dateOnly_isMidnight() {
        let task = SyncTask.fromObsidianLine("- [ ] Plain 📅 2026-03-15", filePath: "/n.md", lineNumber: 1)
        let c = comps(task?.dueDate)
        XCTAssertEqual(c?.hour, 0); XCTAssertEqual(c?.minute, 0)
        XCTAssertEqual(task?.title, "Plain")
    }

    func test_startTime_parsed() {
        let task = SyncTask.fromObsidianLine("- [ ] Trip 🛫 2026-03-10 08:15 📅 2026-03-15", filePath: "/n.md", lineNumber: 1)
        XCTAssertEqual(comps(task?.startDate)?.hour, 8)
        XCTAssertEqual(comps(task?.startDate)?.minute, 15)
        XCTAssertEqual(comps(task?.dueDate)?.day, 15)
        XCTAssertEqual(task?.title, "Trip")
    }

    func test_backCompat_noTimeUnchanged() {
        // A plain date line must parse exactly as before (regression guard).
        let task = SyncTask.fromObsidianLine("- [ ] Pay rent 📅 2024-01-20 #bills", filePath: "/n.md", lineNumber: 1)
        XCTAssertEqual(task?.title, "Pay rent")
        XCTAssertEqual(task?.tags, ["#bills"])
        XCTAssertEqual(comps(task?.dueDate)?.day, 20)
    }

    // MARK: - Alarm fire-date computation

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func test_alarm_allDay_usesConfiguredHour() {
        let due = date(2026, 3, 15) // midnight
        let fire = SyncTask.alarmFireDate(due: due, includeTime: false, allDayHour: 9)
        let c = cal.dateComponents([.day, .hour, .minute], from: fire)
        XCTAssertEqual(c.day, 15); XCTAssertEqual(c.hour, 9); XCTAssertEqual(c.minute, 0)
    }

    func test_alarm_withTime_firesAtThatTime() {
        let due = date(2026, 3, 15, 14, 30)
        let fire = SyncTask.alarmFireDate(due: due, includeTime: true, allDayHour: 9)
        XCTAssertEqual(fire, due, "A timed due date alarms at exactly that time.")
    }

    func test_alarm_timePresentButTimeSyncOff_usesConfiguredHour() {
        // If the user hasn't enabled time sync, even a timed due falls back to
        // the all-day hour (we won't surface a time we're not syncing).
        let due = date(2026, 3, 15, 14, 30)
        let fire = SyncTask.alarmFireDate(due: due, includeTime: false, allDayHour: 8)
        XCTAssertEqual(cal.dateComponents([.hour, .minute], from: fire).hour, 8)
    }

    func test_alarm_hourClamped() {
        let due = date(2026, 3, 15)
        let fire = SyncTask.alarmFireDate(due: due, includeTime: false, allDayHour: 99)
        XCTAssertEqual(cal.dateComponents([.hour], from: fire).hour, 23, "Out-of-range hour clamps to 23.")
    }

    // MARK: - Config back-compat

    func test_configDefaults() {
        let cfg = SyncConfiguration()
        XCTAssertFalse(cfg.addReminderAlarm, "Alarms are opt-in — off by default.")
        XCTAssertEqual(cfg.reminderAlarmHour, 9)
    }
}
