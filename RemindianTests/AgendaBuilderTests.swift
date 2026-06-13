import XCTest
@testable import Remindian

/// Tests for the menu-bar "Today" agenda filter (v5.19.0).
final class AgendaBuilderTests: XCTestCase {

    private let cal = Calendar.current
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 10))! }

    private func task(_ title: String, due dayOffset: Int?, completed: Bool = false) -> SyncTask {
        let due = dayOffset.map { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: now))! }
        return SyncTask(title: title, isCompleted: completed, dueDate: due)
    }

    func test_includesOverdueAndToday_excludesFuture() {
        let tasks = [
            task("Yesterday", due: -1),
            task("Today", due: 0),
            task("Tomorrow", due: 1),
            task("Next week", due: 7),
        ]
        let agenda = AgendaBuilder.build(from: tasks, now: now)
        XCTAssertEqual(agenda.map { $0.title }, ["Yesterday", "Today"], "Only overdue + due-today, soonest first.")
    }

    func test_excludesCompletedAndNoDueDate() {
        let tasks = [
            task("Done today", due: 0, completed: true),
            task("No date", due: nil),
            task("Open today", due: 0),
        ]
        let agenda = AgendaBuilder.build(from: tasks, now: now)
        XCTAssertEqual(agenda.map { $0.title }, ["Open today"])
    }

    func test_sortedSoonestFirst() {
        let tasks = [task("d0", due: 0), task("d-3", due: -3), task("d-1", due: -1)]
        let agenda = AgendaBuilder.build(from: tasks, now: now)
        XCTAssertEqual(agenda.map { $0.title }, ["d-3", "d-1", "d0"])
    }

    func test_isOverdue() {
        XCTAssertTrue(AgendaBuilder.isOverdue(task("y", due: -1), now: now))
        XCTAssertFalse(AgendaBuilder.isOverdue(task("t", due: 0), now: now), "Due today is not overdue.")
        XCTAssertFalse(AgendaBuilder.isOverdue(task("n", due: nil), now: now))
    }

    func test_emptyInput() {
        XCTAssertTrue(AgendaBuilder.build(from: [], now: now).isEmpty)
    }
}
