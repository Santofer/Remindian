import XCTest
@testable import Remindian

/// What "Remove Duplicate Reminders" is allowed to delete.
///
/// The cleanup used to group *every* reminder in *every* list by title. With
/// "also match copies with different due dates" on, that made the completion
/// history of the user's own repeating reminders — and anything in a shared list
/// or created by another app — duplicates to be deleted. It may only touch what
/// Remindian manages, and must never delete a reminder a vault task is tied to.
final class DuplicateRemindersPlanTests: XCTestCase {

    private func day(_ month: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = month; c.day = 1
        return Calendar.current.date(from: c)!
    }

    private func item(_ id: String, _ title: String = "Pay rent", list: String = "L1", completed: Bool = true,
                      due: Date? = nil, linked: Bool = false) -> DuplicateReminders.Item {
        DuplicateReminders.Item(id: id, title: title, listId: list, listName: list, isCompleted: completed, due: due, isLinked: linked)
    }

    private func removed(_ items: [DuplicateReminders.Item], mapped: Set<String> = [], ignoreDueDate: Bool = true) -> Set<String> {
        Set(DuplicateReminders.plan(items, mappedIds: mapped, ignoreDueDate: ignoreDueDate).flatMap(\.remove))
    }

    // MARK: Scope

    func test_theUsersOwnRepeatingReminderHistoryIsNeverTouched() {
        // Twelve completed occurrences of a reminder Remindian has nothing to do with.
        let history = (1...12).map { item("own-\($0)", "Take vitamins", due: day($0)) }
        XCTAssertEqual(removed(history), [])
        XCTAssertEqual(removed(history, ignoreDueDate: false), [])
    }

    func test_aGroupIsInScopeOnceRemindianManagesOneOfItsMembers() {
        let viaLink = [item("a", linked: true), item("b"), item("c")]
        XCTAssertEqual(removed(viaLink).count, 2)

        let viaMapping = [item("a"), item("b"), item("c")]
        XCTAssertEqual(removed(viaMapping, mapped: ["b"]), ["a", "c"])
    }

    func test_sameTitleInAnotherListIsADifferentGroup() {
        let items = [item("a", linked: true), item("b"), item("shared-1", list: "Shared"), item("shared-2", list: "Shared")]
        XCTAssertEqual(removed(items), ["b"], "The copies in the other list have no managed member")
    }

    // MARK: What survives

    func test_mappedRemindersAreNeverDeleted() {
        // Deleting a mapped reminder would only make the next sync re-create it.
        let items = [item("open", completed: false, due: day(12), linked: true), item("mapped-done", due: day(6)), item("old", due: day(5))]
        XCTAssertEqual(removed(items, mapped: ["mapped-done"]), ["old"])
    }

    /// The shape left behind by the recurring-reminder bug: several live copies,
    /// one mapped completed copy, and a pile of completed ones.
    func test_recurringPileUpCollapsesToOneLiveCopyPlusTheMappedOne() {
        var items = (1...4).map { item("live-\($0)", completed: false, due: day(12), linked: true) }
        items.append(item("mapped", due: day(6), linked: true))
        items += (1...500).map { item("copy-\($0)", due: day(6), linked: true) }

        let plan = DuplicateReminders.plan(items, mappedIds: ["mapped"], ignoreDueDate: true)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].total, 505)
        XCTAssertEqual(plan[0].remove.count, 503)
        XCTAssertEqual(plan[0].removeOpen, 3)
        let gone = Set(plan[0].remove)
        XCTAssertFalse(gone.contains("mapped"))
        XCTAssertEqual((1...4).filter { !gone.contains("live-\($0)") }.count, 1, "Exactly one live copy stays")
    }

    func test_openBeatsCompleted_thenTheLatestDueDate() {
        let items = [item("done-late", due: day(12), linked: true), item("open-early", completed: false, due: day(3)), item("open-late", completed: false, due: day(9))]
        XCTAssertEqual(removed(items), ["done-late", "open-early"])
    }

    // MARK: Strict mode

    func test_strictModeOnlyMatchesSameDayAndState_andKeepsTheLinkedCopy() {
        let items = [item("plain", due: day(6)), item("linked", due: day(6), linked: true),
                     item("other-day", due: day(7), linked: true), item("open", completed: false, due: day(6), linked: true)]
        XCTAssertEqual(removed(items, ignoreDueDate: false), ["plain"])
    }

    func test_nothingToRemoveYieldsNoGroup() {
        XCTAssertTrue(DuplicateReminders.plan([item("only", linked: true)], mappedIds: [], ignoreDueDate: true).isEmpty)
        XCTAssertTrue(DuplicateReminders.plan([item("a"), item("b")], mappedIds: ["a", "b"], ignoreDueDate: true).isEmpty,
                      "Two mapped copies: both are kept, so there is no group to report")
    }
}
