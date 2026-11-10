import XCTest
@testable import Remindian

/// Regression tests for the v5.9.0 work that resolved 4 issues reported by
/// @cjhille on 2026-05-03. Each test names the issue it guards.
///
/// - #63: Custom inline status markers (`[<]`, `[/]`, `[?]`, `[-]`).
/// - #64: Hierarchical tag (`#task/work`) didn't resolve as the most-specific
///   list mapping.
/// - #65: URL fragments `#section` inside URLs were parsed as tags.
/// - #66 Phase 1: Indented subtasks fell through to default list when they
///   had no tag of their own.
///
/// If any of these fail, the corresponding bug is back. The names are
/// intentionally specific so a future maintainer who breaks one of them sees
/// exactly which issue they regressed.
final class V5_9_0_RegressionTests: XCTestCase {

    // MARK: - #63: Custom status markers

    func test_63_parsesInProgressMarkerAsOpen() {
        let task = SyncTask.fromObsidianLine(
            "- [/] Refactor parser",
            filePath: "/test.md",
            lineNumber: 1,
            openMarkers: [" ", "/"],
            completedMarkers: ["x", "X"]
        )
        XCTAssertNotNil(task, "`[/]` is a valid task marker when configured as open. (#63)")
        XCTAssertEqual(task?.title, "Refactor parser")
        XCTAssertEqual(task?.isCompleted, false)
    }

    func test_63_parsesCancelledMarkerAsCompleted() {
        let task = SyncTask.fromObsidianLine(
            "- [-] Drop scope creep",
            filePath: "/test.md",
            lineNumber: 1,
            openMarkers: [" ", "/"],
            completedMarkers: ["x", "X", "-"]
        )
        XCTAssertNotNil(task)
        XCTAssertEqual(
            task?.isCompleted, true,
            "`[-]` configured as a completed marker must be treated as done. (#63)"
        )
    }

    func test_63_unknownMarkerDefaultsToOpen() {
        let task = SyncTask.fromObsidianLine(
            "- [!] Custom marker someone invented",
            filePath: "/test.md",
            lineNumber: 1
        )
        XCTAssertNotNil(task, "Unknown markers should still be recognized as tasks (lenient parsing). (#63)")
        XCTAssertEqual(
            task?.isCompleted, false,
            "Unknown markers default to open — safer than silently treating as done. (#63)"
        )
    }

    func test_63_legacyOnlyOpenAndCompletedStillWork() {
        // Backwards-compat: parsing with the default marker sets matches v5.8.x.
        let open = SyncTask.fromObsidianLine("- [ ] Open task", filePath: "/t.md", lineNumber: 1)
        XCTAssertEqual(open?.isCompleted, false)

        let completed = SyncTask.fromObsidianLine("- [x] Done", filePath: "/t.md", lineNumber: 1)
        XCTAssertEqual(completed?.isCompleted, true)

        let completedCap = SyncTask.fromObsidianLine("- [X] Done", filePath: "/t.md", lineNumber: 1)
        XCTAssertEqual(completedCap?.isCompleted, true)
    }

    func test_63_wikilinkRejectedAsTask() {
        // Defensive: `- [[Name]]` must NOT be parsed as a task even though
        // the widened regex could in principle accept `[` as a marker.
        let task = SyncTask.fromObsidianLine("- [[My Note]]", filePath: "/t.md", lineNumber: 1)
        XCTAssertNil(task, "Wikilink syntax `- [[...]]` is not a task. (#63 safety)")
    }

    func test_63_markTaskCompleteOnInProgressMarkerWritesX() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-63-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let original = "- [/] In progress task #work"
        let fileURL = vault.appendingPathComponent("Note.md")
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let service = ObsidianService()
        try service.markTaskComplete(
            filePath: "/Note.md",
            lineNumber: 1,
            originalLine: original,
            completionDate: ISO8601DateFormatter().date(from: "2026-05-03T12:00:00Z")!,
            vaultPath: vault.path
        )

        let updated = try String(contentsOf: fileURL, encoding: .utf8).components(separatedBy: "\n")[0]
        XCTAssertTrue(
            updated.hasPrefix("- [x]"),
            "Marking `- [/]` complete must write `- [x]`, not be skipped as already-complete. (#63 regression)"
        )
        XCTAssertTrue(updated.contains("#work"), "Other metadata preserved.")
        XCTAssertTrue(updated.contains("✅"), "Completion date appended.")
    }

    func test_63_markTaskIncompleteOnCustomCompletedMarkerWritesSpace() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-63-inc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        // User has `-` configured as completed; we cancel the cancellation.
        let original = "- [-] Was cancelled ✅ 2026-05-01"
        let fileURL = vault.appendingPathComponent("Note.md")
        try original.write(to: fileURL, atomically: true, encoding: .utf8)

        let service = ObsidianService()
        try service.markTaskIncomplete(
            filePath: "/Note.md",
            lineNumber: 1,
            originalLine: original,
            vaultPath: vault.path
        )

        let updated = try String(contentsOf: fileURL, encoding: .utf8).components(separatedBy: "\n")[0]
        XCTAssertTrue(
            updated.hasPrefix("- [ ]"),
            "Marking `- [-]` incomplete must write `- [ ]`, not leave the unknown marker. (#63 regression)"
        )
        XCTAssertFalse(updated.contains("✅"), "Completion date removed.")
    }

    // MARK: - #64: Hierarchical tag mapping

    func test_64_hierarchicalTagPrefersMostSpecificMapping() {
        let config = SyncConfiguration(
            listMappings: [
                .init(obsidianTag: "task", remindersList: "All Tasks"),
                .init(obsidianTag: "task/work", remindersList: "Work Tasks")
            ]
        )

        let result = config.resolveTargetList(
            tag: "task",
            filePath: nil,
            tags: ["#task/work"]
        )

        XCTAssertEqual(
            result, "Work Tasks",
            "Hierarchical tag `#task/work` should match the more-specific mapping for `task/work`, not the bare `task`. (#64)"
        )
    }

    func test_64_hierarchicalTagFallsBackToRootMapping() {
        let config = SyncConfiguration(
            listMappings: [
                .init(obsidianTag: "task", remindersList: "All Tasks")
            ]
        )

        let result = config.resolveTargetList(
            tag: "task",
            filePath: nil,
            tags: ["#task/work"]
        )

        XCTAssertEqual(
            result, "All Tasks",
            "When only the root segment has a mapping, hierarchical tags should fall back to it. (#64 back-compat)"
        )
    }

    func test_64_hierarchicalTagNoMappingFallsBackToAutoCapitalize() {
        let config = SyncConfiguration(defaultList: "Reminders")

        let result = config.resolveTargetList(
            tag: "task",
            filePath: nil,
            tags: ["#task/work"]
        )

        XCTAssertEqual(
            result, "Task",
            "No mapping at all → auto-capitalize the root segment (existing behavior preserved). (#64)"
        )
    }

    func test_64_legacyCallSiteWithoutTagsStillWorks() {
        // Old callers that don't pass `tags:` should still resolve via the
        // bare `tag:` parameter.
        let config = SyncConfiguration(
            listMappings: [.init(obsidianTag: "work", remindersList: "Work List")]
        )
        let result = config.resolveTargetList(tag: "work", filePath: nil)
        XCTAssertEqual(result, "Work List")
    }

    func test_64_deeplyHierarchicalTagTriesEverySegment() {
        let config = SyncConfiguration(
            listMappings: [
                .init(obsidianTag: "work", remindersList: "Work"),
                .init(obsidianTag: "work/clients", remindersList: "Client Work")
            ]
        )

        // Tag is 3 levels deep; should match "work/clients" (most specific that has a mapping).
        let result = config.resolveTargetList(
            tag: "work",
            filePath: nil,
            tags: ["#work/clients/somfy"]
        )

        XCTAssertEqual(result, "Client Work")
    }

    // MARK: - #65: URL fragment / wikilink false-positive tags

    func test_65_urlWithHashFragmentNotParsedAsTag() {
        let task = SyncTask.fromObsidianLine(
            "- [ ] Read https://example.com/page/#section #work",
            filePath: "/test.md",
            lineNumber: 1
        )
        XCTAssertNotNil(task)
        XCTAssertEqual(
            task?.targetList, "work",
            "The legitimate `#work` tag must drive routing, not the `#section` URL fragment. (#65 regression)"
        )
        XCTAssertEqual(task?.tags, ["#work"])
    }

    func test_65_markdownLinkWithHashFragmentNotParsedAsTag() {
        let task = SyncTask.fromObsidianLine(
            "- [ ] Read [the docs](https://example.com/#section) #work",
            filePath: "/test.md",
            lineNumber: 1
        )
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.targetList, "work", "Markdown link form must be protected too. (#65)")
        XCTAssertEqual(task?.tags, ["#work"])
    }

    /// A relative Markdown link to a heading (`[text](Note#heading)`) isn't a
    /// URL, so it wasn't protected: `#heading` became a tag and the reminder was
    /// routed to an auto-created list named after the heading.
    func test_relativeMarkdownLinkWithHeadingNotParsedAsTag() {
        let task = SyncTask.fromObsidianLine(
            "- [ ] Stair Stepping — Workout goal 2 📅 2026-09-30 · [Change day](Journal/Weeklies/2026-W40#workout-goal-date-wg-2026-w40-g2) ^wg-2026-w40-g2",
            filePath: "/Journal/Dailies/2026-09-30.md",
            lineNumber: 1
        )
        XCTAssertNotNil(task)
        XCTAssertEqual(task?.tags, [], "The link's heading anchor must not be a tag")
        XCTAssertNil(task?.targetList)
        XCTAssertTrue(task?.title.contains("[Change day](Journal/Weeklies/2026-W40#workout-goal-date-wg-2026-w40-g2)") ?? false,
                      "The link stays in the title intact. Got: \(task?.title ?? "nil")")
    }

    func test_realTagNextToRelativeMarkdownLinkStillParses() {
        let task = SyncTask.fromObsidianLine(
            "- [ ] Review [notes](Projects/Plan#Goals) #work",
            filePath: "/test.md",
            lineNumber: 1
        )
        XCTAssertEqual(task?.tags, ["#work"])
        XCTAssertEqual(task?.targetList, "work")
    }

    func test_65_wikilinkWithHeaderAnchorNotParsedAsTag() {
        let task = SyncTask.fromObsidianLine(
            "- [ ] Review [[My Note#section]] #work",
            filePath: "/test.md",
            lineNumber: 1
        )
        XCTAssertNotNil(task)
        XCTAssertEqual(
            task?.targetList, "work",
            "Wikilink header anchors look like `#section` but must not be parsed as tags. (#65)"
        )
        XCTAssertEqual(task?.tags, ["#work"])
    }

    func test_65_codeSpanTagNotParsed() {
        let task = SyncTask.fromObsidianLine(
            "- [ ] Document `#deprecated` API",
            filePath: "/test.md",
            lineNumber: 1
        )
        XCTAssertNotNil(task)
        XCTAssertTrue(
            task?.tags.isEmpty ?? false,
            "Tags inside code spans should be treated as literal text, not extracted. (#65)"
        )
    }

    func test_65_legitimateTagAfterURLStillParsed() {
        // Regression guard for the fix: don't over-aggressively drop tags.
        let task = SyncTask.fromObsidianLine(
            "- [ ] Visit https://example.com #work",
            filePath: "/test.md",
            lineNumber: 1
        )
        XCTAssertEqual(task?.targetList, "work")
        XCTAssertEqual(task?.tags, ["#work"])
    }

    func test_65_multipleURLsBeforeRealTag() {
        let task = SyncTask.fromObsidianLine(
            "- [ ] See https://a.com/#x and https://b.com/#y #real",
            filePath: "/test.md",
            lineNumber: 1
        )
        XCTAssertEqual(task?.targetList, "real")
        XCTAssertEqual(task?.tags, ["#real"])
    }

    func test_65_bareTagAtStartOfLineIsStillATag() {
        // Trivial case: no URLs at all. Old behavior preserved.
        let task = SyncTask.fromObsidianLine(
            "- [ ] #urgent Fix the build",
            filePath: "/test.md",
            lineNumber: 1
        )
        XCTAssertEqual(task?.targetList, "urgent")
    }

    // MARK: - #66: Subtask tag inheritance

    func test_66_indentedChildInheritsParentTargetList() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-66-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let content = """
        - [ ] Parent task #work
        \t- [ ] Child task
        """
        let fileURL = vault.appendingPathComponent("Note.md")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let tasks = try ObsidianService().parseTasksFromFile(fileURL, vaultPath: vault.path)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].targetList, "work", "Parent has its own tag.")
        XCTAssertEqual(
            tasks[1].targetList, "work",
            "Child inherits the parent's targetList — addresses the user pain in #66."
        )
    }

    func test_66_childWithOwnTagOverridesInheritance() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-66-own-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let content = """
        - [ ] Parent #work
        \t- [ ] Child with own tag #personal
        """
        let fileURL = vault.appendingPathComponent("Note.md")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let tasks = try ObsidianService().parseTasksFromFile(fileURL, vaultPath: vault.path)
        XCTAssertEqual(tasks[1].targetList, "personal", "Explicit child tag wins over inheritance.")
    }

    func test_66_deeplyNestedTaskInheritsFromNearestTaggedAncestor() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-66-deep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let content = """
        - [ ] Top #work
        \t- [ ] Middle
        \t\t- [ ] Bottom
        """
        let fileURL = vault.appendingPathComponent("Note.md")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let tasks = try ObsidianService().parseTasksFromFile(fileURL, vaultPath: vault.path)
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks[0].targetList, "work")
        XCTAssertEqual(tasks[1].targetList, "work", "Middle inherits from Top.")
        XCTAssertEqual(tasks[2].targetList, "work", "Bottom inherits transitively (Middle now carries the tag).")
    }

    func test_66_siblingsDoNotInheritFromEachOther() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-66-sib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let content = """
        - [ ] First #work
        - [ ] Second
        """
        let fileURL = vault.appendingPathComponent("Note.md")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let tasks = try ObsidianService().parseTasksFromFile(fileURL, vaultPath: vault.path)
        XCTAssertEqual(tasks[0].targetList, "work")
        XCTAssertNil(
            tasks[1].targetList,
            "Same-indent siblings are NOT in parent/child relationship — must not inherit. (#66)"
        )
    }

    func test_66_parentWithoutTagDoesNotCorruptChild() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-66-untagged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let content = """
        - [ ] Untagged parent
        \t- [ ] Untagged child
        """
        let fileURL = vault.appendingPathComponent("Note.md")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let tasks = try ObsidianService().parseTasksFromFile(fileURL, vaultPath: vault.path)
        XCTAssertNil(tasks[0].targetList)
        XCTAssertNil(
            tasks[1].targetList,
            "If parent has no tag either, child stays untagged — graceful degradation. (#66)"
        )
    }

    func test_66_inheritedTagAppearsInChildTagsArray() throws {
        // The inherited tag needs to be in the `tags` array so it survives
        // toObsidianLine() reserialization (used by inbox writeback). Without
        // this the routing hint would be lost on writeback.
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("remindian-66-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let content = """
        - [ ] Project Alpha #work
        \t- [ ] Sub task with no tag
        """
        let fileURL = vault.appendingPathComponent("Note.md")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let tasks = try ObsidianService().parseTasksFromFile(fileURL, vaultPath: vault.path)
        XCTAssertTrue(
            tasks[1].tags.contains("#work"),
            "Inherited targetList must also propagate as a tag entry so reserialization preserves it. (#66)"
        )
    }
}
