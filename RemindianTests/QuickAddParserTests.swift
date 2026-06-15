import XCTest
@testable import Remindian

/// Tests for the quick-add natural-language parser (v5.18.0).
final class QuickAddParserTests: XCTestCase {

    private let cal = Calendar.current

    func test_plainTitle() {
        let t = QuickAddParser.parse("Email Sam about the deck")
        XCTAssertEqual(t.title, "Email Sam about the deck")
        XCTAssertEqual(t.priority, SyncTask.Priority.none)
        XCTAssertNil(t.dueDate)
        XCTAssertTrue(t.tags.isEmpty)
    }

    func test_priorityLevels() {
        XCTAssertEqual(QuickAddParser.parse("Ship it !!!").priority, .high)
        XCTAssertEqual(QuickAddParser.parse("Review PR !!").priority, .medium)
        XCTAssertEqual(QuickAddParser.parse("Water plants !").priority, .low)
    }

    func test_priorityStrippedFromTitle() {
        let t = QuickAddParser.parse("Pay rent !!")
        XCTAssertEqual(t.title, "Pay rent")
        XCTAssertEqual(t.priority, .medium)
    }

    func test_bangInsideWordNotPriority() {
        let t = QuickAddParser.parse("Fix the bug!")
        // "bug!" is glued to a word → not a standalone priority token.
        XCTAssertEqual(t.priority, SyncTask.Priority.none)
        XCTAssertEqual(t.title, "Fix the bug!")
    }

    func test_tagsExtracted() {
        let t = QuickAddParser.parse("Call plumber #home #urgent")
        XCTAssertEqual(t.tags, ["#home", "#urgent"])
        XCTAssertEqual(t.title, "Call plumber")
        XCTAssertEqual(t.targetList, "home")
    }

    func test_absoluteDateParsedAndStripped() {
        let t = QuickAddParser.parse("Submit taxes April 15 2026")
        XCTAssertNotNil(t.dueDate, "An explicit date must be detected.")
        if let due = t.dueDate {
            let comps = cal.dateComponents([.year, .month, .day], from: due)
            XCTAssertEqual(comps.year, 2026)
            XCTAssertEqual(comps.month, 4)
            XCTAssertEqual(comps.day, 15)
        }
        XCTAssertTrue(t.title.localizedCaseInsensitiveContains("Submit taxes"))
        XCTAssertFalse(t.title.contains("2026"), "The date phrase should be removed from the title. Got: \(t.title)")
    }

    func test_relativeDateProducesFutureDate() {
        let t = QuickAddParser.parse("Standup tomorrow")
        XCTAssertNotNil(t.dueDate, "\"tomorrow\" should resolve to a date.")
        if let due = t.dueDate {
            XCTAssertGreaterThan(due, Date().addingTimeInterval(-3600), "Should be roughly now or later.")
        }
        XCTAssertTrue(t.title.localizedCaseInsensitiveContains("Standup"))
    }

    func test_combined() {
        let t = QuickAddParser.parse("Renew passport April 15 2026 !!! #admin")
        XCTAssertEqual(t.priority, .high)
        XCTAssertEqual(t.tags, ["#admin"])
        XCTAssertNotNil(t.dueDate)
        XCTAssertTrue(t.title.localizedCaseInsensitiveContains("Renew passport"))
        XCTAssertFalse(t.title.contains("!"))
        XCTAssertFalse(t.title.contains("#admin"))
    }

    // MARK: - Recurrence (Quick-add recurrence)

    func test_recurrence_englishIntervals() {
        XCTAssertEqual(QuickAddParser.parse("Water plants every day").recurrenceRule, "every day")
        XCTAssertEqual(QuickAddParser.parse("Standup every 2 weeks").recurrenceRule, "every 2 weeks")
        XCTAssertEqual(QuickAddParser.parse("Pay rent every month").recurrenceRule, "every month")
        XCTAssertEqual(QuickAddParser.parse("Renew domain every 1 year").recurrenceRule, "every year")
        XCTAssertEqual(QuickAddParser.parse("Deep clean every 3 months").recurrenceRule, "every 3 months")
    }

    func test_recurrence_englishAdverbs() {
        XCTAssertEqual(QuickAddParser.parse("Backup weekly").recurrenceRule, "every week")
        XCTAssertEqual(QuickAddParser.parse("Standup daily").recurrenceRule, "every day")
        XCTAssertEqual(QuickAddParser.parse("Report monthly").recurrenceRule, "every month")
        XCTAssertEqual(QuickAddParser.parse("Taxes annually").recurrenceRule, "every year")
    }

    func test_recurrence_french() {
        XCTAssertEqual(QuickAddParser.parse("Arroser les plantes tous les jours").recurrenceRule, "every day")
        XCTAssertEqual(QuickAddParser.parse("Réunion chaque semaine").recurrenceRule, "every week")
        XCTAssertEqual(QuickAddParser.parse("Payer le loyer tous les mois").recurrenceRule, "every month")
        XCTAssertEqual(QuickAddParser.parse("Bilan tous les ans").recurrenceRule, "every year")
        XCTAssertEqual(QuickAddParser.parse("Standup toutes les 2 semaines").recurrenceRule, "every 2 weeks")
        XCTAssertEqual(QuickAddParser.parse("Sauvegarde hebdomadaire").recurrenceRule, "every week")
        XCTAssertEqual(QuickAddParser.parse("Rapport mensuel").recurrenceRule, "every month")
    }

    func test_recurrence_strippedFromTitle() {
        let t = QuickAddParser.parse("Pay rent every month")
        XCTAssertEqual(t.title, "Pay rent")
        XCTAssertEqual(t.recurrenceRule, "every month")
    }

    func test_recurrence_noFalsePositives() {
        XCTAssertNil(QuickAddParser.parse("Email Sam").recurrenceRule)
        XCTAssertNil(QuickAddParser.parse("Review everything before launch").recurrenceRule,
                     "\"everything\" must not trigger recurrence.")
        XCTAssertNil(QuickAddParser.parse("Plan the yearbook").recurrenceRule,
                     "\"yearbook\" must not match the \"year\" unit.")
        XCTAssertNil(QuickAddParser.parse("Each item needs review").recurrenceRule,
                     "\"each\" without a following time unit is not a recurrence.")
    }

    func test_recurrence_combinedWithDatePriorityTag() {
        let t = QuickAddParser.parse("Pay rent friday every month #home !!!")
        XCTAssertEqual(t.priority, .high)
        XCTAssertEqual(t.tags, ["#home"])
        XCTAssertEqual(t.recurrenceRule, "every month")
        XCTAssertNotNil(t.dueDate, "\"friday\" still resolves to a due date.")
        XCTAssertTrue(t.title.localizedCaseInsensitiveContains("Pay rent"))
        XCTAssertFalse(t.title.lowercased().contains("every month"))
        XCTAssertFalse(t.title.contains("#home"))
        XCTAssertFalse(t.title.contains("!"))
    }

    func test_emptyAndWhitespace() {
        XCTAssertEqual(QuickAddParser.parse("   ").title, "")
    }

    func test_titleNeverEmptyWhenInputHasContent() {
        // If date/priority/tags consume everything, fall back to the raw input.
        let t = QuickAddParser.parse("#onlytag")
        XCTAssertFalse(t.title.isEmpty)
    }
}
