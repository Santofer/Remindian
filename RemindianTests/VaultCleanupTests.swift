import XCTest
@testable import Remindian

/// Duplicate task lines *inside* the vault — the debris that a sync feedback loop
/// could append to the inbox, one copy per recurrence.
final class VaultCleanupTests: XCTestCase {

    func test_findsRepeatedCompletedCopiesWithDifferentDates() {
        // Exactly the shape a real vault accumulated: same task, appended monthly,
        // each copy carrying a different completion date.
        let content = """
        - [x] Payer la facture ✅ 2026-04-30 #Netspace
        - [x] Payer la facture ✅ 2026-05-01 #Netspace
        - [x] Payer la facture ✅ 2026-05-07 #Netspace
        """
        let duplicates = VaultCleanup.duplicateTaskLines(in: content)
        XCTAssertEqual(duplicates.count, 2, "Keep the first, flag the rest")
        XCTAssertEqual(duplicates.map(\.lineIndex), [1, 2])
    }

    func test_keepsGenuinelyDifferentTasks() {
        let content = """
        - [ ] Buy milk
        - [ ] Buy bread
        """
        XCTAssertTrue(VaultCleanup.duplicateTaskLines(in: content).isEmpty)
    }

    /// An open copy and a completed copy are different states of the work, not
    /// duplicates — removing the open one would delete a live task.
    func test_openAndCompletedCopiesAreNotDuplicates() {
        let content = """
        - [x] Pay rent ✅ 2026-05-01
        - [ ] Pay rent 📅 2026-06-01
        """
        XCTAssertTrue(VaultCleanup.duplicateTaskLines(in: content).isEmpty)
    }

    func test_ignoresNonTaskLines() {
        let content = """
        # Heading
        Some prose about buying milk.
        - [ ] Buy milk
        """
        XCTAssertTrue(VaultCleanup.duplicateTaskLines(in: content).isEmpty)
    }

    func test_matchingIsCaseInsensitive() {
        let content = """
        - [ ] Buy Milk
        - [ ] buy milk
        """
        XCTAssertEqual(VaultCleanup.duplicateTaskLines(in: content).count, 1)
    }

    func test_removingLinesKeepsEverythingElseIntact() {
        let content = """
        # Notes
        - [x] Dup ✅ 2026-01-01
        Some prose.
        - [x] Dup ✅ 2026-02-01
        - [ ] Keep me
        """
        let duplicates = VaultCleanup.duplicateTaskLines(in: content)
        let cleaned = VaultCleanup.removingLines(duplicates.map(\.lineIndex), from: content)

        XCTAssertTrue(cleaned.contains("# Notes"))
        XCTAssertTrue(cleaned.contains("Some prose."))
        XCTAssertTrue(cleaned.contains("- [ ] Keep me"))
        XCTAssertEqual(cleaned.components(separatedBy: "Dup").count - 1, 1, "Exactly one copy survives")
    }

    func test_removingNothingLeavesContentUnchanged() {
        let content = "- [ ] Only task\nProse"
        XCTAssertEqual(VaultCleanup.removingLines([], from: content), content)
    }
}
