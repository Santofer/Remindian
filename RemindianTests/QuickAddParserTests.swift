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

    func test_emptyAndWhitespace() {
        XCTAssertEqual(QuickAddParser.parse("   ").title, "")
    }

    func test_titleNeverEmptyWhenInputHasContent() {
        // If date/priority/tags consume everything, fall back to the raw input.
        let t = QuickAddParser.parse("#onlytag")
        XCTAssertFalse(t.title.isEmpty)
    }
}
