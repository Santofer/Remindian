import XCTest
@testable import Remindian

/// Tests for the floating pinned-tasks window's grouping/sorting (v5.23.0).
final class PinnedTasksOrganizerTests: XCTestCase {

    private let cal = Calendar.current
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 10))! }

    private func task(
        _ title: String, due dayOffset: Int? = nil, priority: SyncTask.Priority = .none,
        tags: [String] = [], recurrence: String? = nil, completed: Bool = false
    ) -> SyncTask {
        let due = dayOffset.map { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: now))! }
        return SyncTask(title: title, isCompleted: completed, priority: priority,
                        dueDate: due, tags: tags, recurrenceRule: recurrence)
    }

    func test_byDate_bucketsAndOrder() {
        let tasks = [
            task("Late", due: -2), task("Today", due: 0), task("Midweek", due: 3),
            task("Later", due: 20), task("Someday"),
        ]
        let s = PinnedTasksOrganizer.sections(from: tasks, grouping: .date, now: now)
        XCTAssertEqual(s.map { $0.title }, ["Overdue", "Today", "This week", "Later", "No date"])
        XCTAssertEqual(s[0].accent, .red)
        XCTAssertEqual(s[0].tasks.first?.title, "Late")
    }

    func test_byDate_excludesCompleted() {
        let s = PinnedTasksOrganizer.sections(
            from: [task("Done", due: 0, completed: true), task("Open", due: 0)],
            grouping: .date, now: now)
        XCTAssertEqual(s.flatMap { $0.tasks }.map { $0.title }, ["Open"])
    }

    func test_byPriority_order() {
        let tasks = [task("a", priority: .low), task("b", priority: .high),
                     task("c", priority: .medium), task("d")]
        let s = PinnedTasksOrganizer.sections(from: tasks, grouping: .priority, now: now)
        XCTAssertEqual(s.map { $0.title }, ["High", "Medium", "Low", "No priority"])
        XCTAssertEqual(s.first?.accent, .red)
    }

    func test_byTag_alphabeticalWithNoTagLast() {
        let tasks = [
            task("x", tags: ["#work"]), task("y", tags: ["#admin"]),
            task("z"), task("w", tags: ["#admin"]),
        ]
        let s = PinnedTasksOrganizer.sections(from: tasks, grouping: .tag, now: now)
        XCTAssertEqual(s.map { $0.title }, ["#admin", "#work", "No tag"])
        XCTAssertEqual(s.first?.tasks.count, 2, "Both #admin tasks grouped.")
        XCTAssertEqual(s.last?.accent, .gray)
    }

    func test_byRecurrence_split() {
        let tasks = [task("r1", recurrence: "every week"), task("o1"),
                     task("r2", recurrence: "every month")]
        let s = PinnedTasksOrganizer.sections(from: tasks, grouping: .recurrence, now: now)
        XCTAssertEqual(s.map { $0.title }, ["Recurring", "One-off"])
        XCTAssertEqual(s.first?.tasks.count, 2)
        XCTAssertEqual(s.first?.accent, .purple)
    }

    func test_dedupesAcrossCopies() {
        // Same task scanned from two files collapses to one row.
        let tasks = [task("Pay rent", due: 0), task("PAY RENT", due: 0), task("Pay rent", due: -1)]
        let s = PinnedTasksOrganizer.sections(from: tasks, grouping: .date, now: now)
        let payRent = s.flatMap { $0.tasks }.filter { $0.title.lowercased() == "pay rent" }
        XCTAssertEqual(payRent.count, 2, "One per distinct due day, de-duplicated across copies.")
    }

    func test_emptyInput() {
        XCTAssertTrue(PinnedTasksOrganizer.sections(from: [], grouping: .date, now: now).isEmpty)
    }

    func test_emptySectionsOmitted() {
        // Only overdue present → only the Overdue section, nothing else.
        let s = PinnedTasksOrganizer.sections(from: [task("Late", due: -1)], grouping: .date, now: now)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s.first?.title, "Overdue")
    }
}
