import XCTest
@testable import Remindian

/// Tests for `TaskNotesSource.slugify` — the Unicode-aware filename slug.
///
/// **History.** #73 stopped non-ASCII letters from being deleted, but did so by
/// *transliterating* them (å→a, ö→o), which Swedish/Spanish/CJK users found
/// lossy and "ugly" (#79). The slug now **preserves** Unicode letters of any
/// script, only stripping characters that are unsafe/noisy in a filename. The
/// displayed title always lives intact in the note's YAML frontmatter; this is
/// purely the on-disk filename.
final class TaskNotesSlugTests: XCTestCase {

    func test_79_swedishAccentsPreserved() {
        // The exact report: "Nu försöker vi med åäö" kept the letters, not folded.
        XCTAssertEqual(TaskNotesSource.slugify("Nu försöker vi med åäö"),
                       "nu-försöker-vi-med-åäö")
        XCTAssertEqual(TaskNotesSource.slugify("Från Mac till lördag"),
                       "från-mac-till-lördag")
    }

    func test_79_spanishAndFrenchPreserved() {
        XCTAssertEqual(TaskNotesSource.slugify("Mañana por la mañana"), "mañana-por-la-mañana")
        XCTAssertEqual(TaskNotesSource.slugify("Réunion à café crème"), "réunion-à-café-crème")
    }

    func test_79_germanPreserved() {
        XCTAssertEqual(TaskNotesSource.slugify("Über Größe Wäsche"), "über-größe-wäsche")
    }

    func test_79_cjkAndCyrillicPreserved() {
        XCTAssertEqual(TaskNotesSource.slugify("买牛奶"), "买牛奶")
        XCTAssertEqual(TaskNotesSource.slugify("Привет мир"), "привет-мир")
    }

    func test_79_emojiOnlyTitleFallsBack() {
        // Emoji are not letters/marks/numbers → stripped → empty → stable token.
        let slug = TaskNotesSource.slugify("🎉🎊")
        XCTAssertTrue(slug.hasPrefix("task-"), "Emoji-only title → fallback: \(slug)")
    }

    func test_79_punctuationStrippedEdgesTrimmed() {
        XCTAssertEqual(TaskNotesSource.slugify("!!! Important !!!"), "important")
    }

    func test_79_multipleSpacesCollapse() {
        XCTAssertEqual(TaskNotesSource.slugify("a    b\t c"), "a-b-c")
    }

    func test_79_maxLengthRespected() {
        let long = String(repeating: "word ", count: 50)
        XCTAssertLessThanOrEqual(TaskNotesSource.slugify(long, maxLength: 50).count, 50)
    }

    func test_79_asciiTitleUnchanged() {
        XCTAssertEqual(TaskNotesSource.slugify("Buy groceries"), "buy-groceries")
        XCTAssertEqual(TaskNotesSource.slugify("Fix bug #123"), "fix-bug-123")
    }

    func test_79_resultAlwaysFilenameSafe() {
        let inputs = ["a/b/c", "..\\..\\etc", "tab\tsep", "emoji🎉mix", "Ωmega",
                      "Привет мир", "", "   ", "---", "café/münchen"]
        let forbidden = CharacterSet(charactersIn: "/\\:\u{00}")
        for input in inputs {
            let slug = TaskNotesSource.slugify(input)
            XCTAssertFalse(slug.isEmpty, "slug empty for input '\(input)'")
            XCTAssertNil(slug.rangeOfCharacter(from: forbidden), "unsafe char in slug '\(slug)' for input '\(input)'")
        }
    }
}
