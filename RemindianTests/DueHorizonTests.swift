import XCTest
@testable import Remindian

/// The due-date horizon limits how far ahead Remindian looks. It must never
/// drop undated work, and it must be exactly off by default.
final class DueHorizonTests: XCTestCase {

    private func daysFromNow(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date())!
    }

    func test_horizonDisabledByDefault() {
        let config = SyncConfiguration()
        XCTAssertEqual(config.maxDueDateHorizonDays, 0)
        XCTAssertNil(SyncEngine.dueDateHorizon(for: config), "No horizon configured = no filtering at all")
    }

    func test_taskInsideHorizonIsKept() throws {
        let config = SyncConfiguration()
        config.maxDueDateHorizonDays = 30
        let horizon = try XCTUnwrap(SyncEngine.dueDateHorizon(for: config))
        let task = SyncTask(title: "Soon", dueDate: daysFromNow(10))
        XCTAssertFalse(SyncEngine.isBeyondDueHorizon(task, horizon: horizon))
    }

    func test_taskBeyondHorizonIsHeldBack() throws {
        let config = SyncConfiguration()
        config.maxDueDateHorizonDays = 30
        let horizon = try XCTUnwrap(SyncEngine.dueDateHorizon(for: config))
        let task = SyncTask(title: "Far", dueDate: daysFromNow(60))
        XCTAssertTrue(SyncEngine.isBeyondDueHorizon(task, horizon: horizon))
    }

    /// The important one: a horizon is about looking ahead, not about discarding
    /// undated work. Most tasks in a vault have no due date at all.
    func test_undatedTaskIsAlwaysInScope() throws {
        let config = SyncConfiguration()
        config.maxDueDateHorizonDays = 7
        let horizon = try XCTUnwrap(SyncEngine.dueDateHorizon(for: config))
        XCTAssertFalse(SyncEngine.isBeyondDueHorizon(SyncTask(title: "No date"), horizon: horizon),
                       "A task without a due date must never be filtered out by the horizon")
    }

    func test_overdueTaskIsAlwaysInScope() throws {
        let config = SyncConfiguration()
        config.maxDueDateHorizonDays = 7
        let horizon = try XCTUnwrap(SyncEngine.dueDateHorizon(for: config))
        XCTAssertFalse(SyncEngine.isBeyondDueHorizon(SyncTask(title: "Late", dueDate: daysFromNow(-5)), horizon: horizon),
                       "Overdue tasks are behind the horizon, not beyond it")
    }

    func test_taskDueOnTheFinalDayIsIncluded() throws {
        // The boundary day counts in full — a task due "in 7 days" at 09:00 must
        // survive a 7-day horizon rather than falling off by hours.
        let config = SyncConfiguration()
        config.maxDueDateHorizonDays = 7
        let horizon = try XCTUnwrap(SyncEngine.dueDateHorizon(for: config))
        let morningOfLastDay = Calendar.current.date(
            bySettingHour: 9, minute: 0, second: 0, of: daysFromNow(7))!
        XCTAssertFalse(SyncEngine.isBeyondDueHorizon(SyncTask(title: "Edge", dueDate: morningOfLastDay), horizon: horizon))
    }

    func test_horizonSurvivesEncodeDecode() throws {
        let config = SyncConfiguration()
        config.maxDueDateHorizonDays = 30
        let decoded = try JSONDecoder().decode(SyncConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.maxDueDateHorizonDays, 30)
    }

    func test_negativeHorizonIsClampedOnDecode() throws {
        let config = SyncConfiguration()
        config.maxDueDateHorizonDays = -5   // corrupt/hand-edited config
        let decoded = try JSONDecoder().decode(SyncConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.maxDueDateHorizonDays, 0, "A negative horizon must degrade to 'no limit', never filter everything")
        XCTAssertNil(SyncEngine.dueDateHorizon(for: decoded))
    }
}
