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

    // MARK: - #99: alarms must follow the due date

    private func day(_ d: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = d; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    /// The reported case: all-day due, 10:00 alarm, due date moved one day later.
    /// The alarm stayed on the old day, and Reminders shows a reminder at its
    /// alarm's date — so the change never visibly arrived.
    func test_99_ourAlarmMovesWithTheDueDate() {
        let result = SyncTask.rescheduledAlarm(day(14, hour: 10), previousDue: day(14), newDue: day(15),
                                               includeTime: false, allDayHour: 10)
        XCTAssertEqual(result, .move(day(15, hour: 10)))
    }

    func test_99_alarmUntouchedWhenDueDateDidNotMove() {
        let result = SyncTask.rescheduledAlarm(day(14, hour: 10), previousDue: day(14), newDue: day(14),
                                               includeTime: false, allDayHour: 10)
        XCTAssertEqual(result, .keep, "No churn when nothing changed")
    }

    func test_99_timedAlarmFollowsATimeChangeOnTheSameDay() {
        let result = SyncTask.rescheduledAlarm(day(14, hour: 14, minute: 30), previousDue: day(14, hour: 14, minute: 30),
                                               newDue: day(14, hour: 16), includeTime: true, allDayHour: 9)
        XCTAssertEqual(result, .move(day(14, hour: 16)))
    }

    /// An alarm someone set at their own time on the due day still belongs to the
    /// day — it follows the date and keeps its time.
    func test_99_otherAlarmOnTheDueDayFollowsAndKeepsItsTime() {
        let result = SyncTask.rescheduledAlarm(day(14, hour: 18, minute: 45), previousDue: day(14), newDue: day(20),
                                               includeTime: false, allDayHour: 10)
        XCTAssertEqual(result, .move(day(20, hour: 18, minute: 45)))
    }

    /// A "day before" nudge is the user's own alarm. It is not ours to move.
    func test_99_alarmOnAnotherDayIsLeftAlone() {
        let result = SyncTask.rescheduledAlarm(day(13, hour: 9), previousDue: day(14), newDue: day(15),
                                               includeTime: false, allDayHour: 10)
        XCTAssertEqual(result, .keep)
    }

    func test_99_ourAlarmIsRemovedWhenTheDueDateIsCleared() {
        XCTAssertEqual(SyncTask.rescheduledAlarm(day(14, hour: 10), previousDue: day(14), newDue: nil,
                                                 includeTime: false, allDayHour: 10), .remove)
        XCTAssertEqual(SyncTask.rescheduledAlarm(day(14, hour: 18), previousDue: day(14), newDue: nil,
                                                 includeTime: false, allDayHour: 10), .keep,
                       "Only the alarm Remindian created is removed with the due date")
    }
}
