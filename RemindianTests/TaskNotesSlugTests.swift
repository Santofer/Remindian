import XCTest
@testable import Remindian

/// Tests for `TaskNotesSource.slugify` — the Unicode-aware filename slug
/// introduced for issue #73.
///
/// **Bug.** The old slug used `[^a-z0-9\s-]` which STRIPPED non-ASCII letters
/// entirely: "Från Mac till lördag" → "frn-mac-till-lrdag". Swedish å/ä/ö,
/// Spanish ñ, French accents all vanished. A fully non-Latin title (CJK)
/// folded to an empty string → a bare ".md" filename.
///
/// **Fix.** Transliterate Latin diacritics before ASCII-filtering, and fall
/// back to a stable token when the result would be empty.
final class TaskNotesSlugTests: XCTestCase {

    func test_73_swedishAccentsTransliterated() {
        let slug = TaskNotesSource.slugify("Från Mac till lördag")
        XCTAssertEqual(
            slug, "fran-mac-till-lordag",
            "Swedish å/ö must transliterate (å→a, ö→o), not get stripped. (#73)"
        )
    }

    func test_73_spanishNTilde() {
        XCTAssertEqual(TaskNotesSource.slugify("Mañana por la mañana"), "manana-por-la-manana")
    }

    func test_73_frenchAccents() {
        XCTAssertEqual(TaskNotesSource.slugify("Réunion à café crème"), "reunion-a-cafe-creme")
    }

    func test_73_germanUmlautsAndEszett() {
        // ü→u, ä→a, ö→o; ß folds to "ss" under diacriticInsensitive on most
        // ICU versions — accept either "ss" or "" but require no data loss of
        // the surrounding letters.
        let slug = TaskNotesSource.slugify("Über Größe Wäsche")
        XCTAssertTrue(slug.hasPrefix("uber-gr"), "ü→u, ö→o preserved: \(slug)")
        XCTAssertTrue(slug.contains("wasche"), "ä→a preserved: \(slug)")
    }

    func test_73_cjkTitleFallsBackToStableToken() {
        // "买牛奶" (buy milk) has no Latin fold → all stripped → empty slug.
        // Must fall back to a non-empty, valid filename token.
        let slug = TaskNotesSource.slugify("买牛奶")
        XCTAssertFalse(slug.isEmpty, "A non-Latin title must never produce an empty slug. (#73)")
        XCTAssertTrue(slug.hasPrefix("task-"), "Empty-slug fallback uses the task- prefix: \(slug)")
        // The fallback must itself be filename-safe.
        XCTAssertNil(slug.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:")))
    }

    func test_73_emojiOnlyTitleFallsBack() {
        let slug = TaskNotesSource.slugify("🎉🎊")
        XCTAssertTrue(slug.hasPrefix("task-"), "Emoji-only title → fallback: \(slug)")
    }

    func test_73_leadingTrailingHyphensTrimmed() {
        // Punctuation at the edges shouldn't leave dangling hyphens.
        let slug = TaskNotesSource.slugify("!!! Important !!!")
        XCTAssertEqual(slug, "important", "Edge hyphens trimmed: \(slug)")
    }

    func test_73_multipleSpacesCollapse() {
        XCTAssertEqual(TaskNotesSource.slugify("a    b\t c"), "a-b-c")
    }

    func test_73_maxLengthRespected() {
        let long = String(repeating: "word ", count: 50) // 250 chars
        let slug = TaskNotesSource.slugify(long, maxLength: 50)
        XCTAssertLessThanOrEqual(slug.count, 50, "maxLength bound respected.")
    }

    func test_73_asciiTitleUnchangedFromOldBehavior() {
        // Back-compat: plain ASCII titles must slug exactly as before so
        // existing files keep matching.
        XCTAssertEqual(TaskNotesSource.slugify("Buy groceries"), "buy-groceries")
        XCTAssertEqual(TaskNotesSource.slugify("Fix bug #123"), "fix-bug-123")
    }

    func test_73_resultIsAlwaysFilenameSafe() {
        // Property: across a spread of nasty inputs, the slug never contains
        // path separators or characters that break a filename.
        let inputs = [
            "a/b/c", "..\\..\\etc", "tab\tsep", "emoji🎉mix", "Ωmega", "Привет мир",
            "", "   ", "---", "café/münchen"
        ]
        let forbidden = CharacterSet(charactersIn: "/\\:\u{00}")
        for input in inputs {
            let slug = TaskNotesSource.slugify(input)
            XCTAssertFalse(slug.isEmpty, "slug empty for input '\(input)'")
            XCTAssertNil(slug.rangeOfCharacter(from: forbidden), "unsafe char in slug '\(slug)' for input '\(input)'")
        }
    }
}
