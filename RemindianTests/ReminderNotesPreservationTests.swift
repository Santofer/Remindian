import XCTest
import EventKit
@testable import Remindian

/// Regression tests for #105.
///
/// **Bug.** `applyToReminder` assigned the whole notes field. With a tag (or a
/// client, folded sub-tasks, or the notes link) it wrote only the generated
/// lines, so text the user had added in Reminders was erased on the next sync.
/// Without any generated lines it wrote `task.notes`, which is `nil` for
/// Obsidian Tasks and Generic Markdown tasks, so the notes were cleared.
///
/// **Fix.** The generated lines are rebuilt at the top of the notes and
/// everything else in the notes is kept.
///
/// Like `ObsidianURIHandlingTests`, these use an in-memory `EKReminder` and need
/// no Reminders access.
final class ReminderNotesPreservationTests: XCTestCase {

    private var store: EKEventStore!

    override func setUp() {
        super.setUp()
        store = EKEventStore()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func makeTask(
        tags: [String] = [],
        clientName: String? = nil,
        subtaskSummary: String? = nil,
        notes: String? = nil
    ) -> SyncTask {
        SyncTask(
            title: "Task",
            tags: tags,
            notes: notes,
            subtaskSummary: subtaskSummary,
            clientName: clientName,
            obsidianSource: SyncTask.ObsidianSource(
                filePath: "/Work.md",
                lineNumber: 1,
                originalLine: "- [ ] Task"
            )
        )
    }

    private func makeReminder(notes: String? = nil) -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.notes = notes
        return reminder
    }

    // MARK: - The reported case

    /// Steps from #105: sync a tagged task, add a line in Reminders, sync again.
    func test_105_userLineSurvivesResyncOfTaggedTask() {
        let task = makeTask(tags: ["#proj/alpha"])
        let reminder = makeReminder()

        task.applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Tags: #proj/alpha")

        reminder.notes = (reminder.notes ?? "") + "\nmy own note"
        task.applyToReminder(reminder)

        XCTAssertEqual(reminder.notes, "Tags: #proj/alpha\nmy own note")
    }

    /// Untagged tasks used to have their notes cleared (`task.notes` is nil for
    /// Obsidian Tasks), not kept as the issue's control case suggested.
    func test_untaggedTaskKeepsUserNotes() {
        let task = makeTask()
        let reminder = makeReminder(notes: "Gate code 4512\nBring the blue folder")

        task.applyToReminder(reminder)

        XCTAssertEqual(reminder.notes, "Gate code 4512\nBring the blue folder")
    }

    func test_untaggedTaskWithNoNotesStaysEmpty() {
        let reminder = makeReminder()
        makeTask().applyToReminder(reminder)
        XCTAssertNil(reminder.notes)
    }

    // MARK: - Generated lines are replaced, not duplicated

    func test_repeatedSyncsAreStable() {
        let task = makeTask(tags: ["#a", "#b"], clientName: "Acme")
        let reminder = makeReminder(notes: "Call before 5")

        task.applyToReminder(reminder)
        let first = reminder.notes
        task.applyToReminder(reminder)
        task.applyToReminder(reminder)

        XCTAssertEqual(first, "Client: Acme\nTags: #a #b\nCall before 5")
        XCTAssertEqual(reminder.notes, first)
    }

    func test_changedTagsReplaceTheOldTagsLine() {
        let reminder = makeReminder(notes: "Tags: #old\nmy own note")
        makeTask(tags: ["#new"]).applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Tags: #new\nmy own note")
    }

    func test_removedTagsDropTheTagsLineButKeepUserText() {
        let reminder = makeReminder(notes: "Tags: #old\nmy own note")
        makeTask().applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "my own note")
    }

    /// The user typed above the generated block. The old `Tags:` line must not
    /// survive as "user text" next to the new one.
    func test_textTypedAboveTheTagsLineDoesNotDuplicateIt() {
        let reminder = makeReminder(notes: "note at the top\nTags: #old")
        makeTask(tags: ["#new"]).applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Tags: #new\nnote at the top")
    }

    func test_notesLinkIsReplacedAndRemovedWhenTurnedOff() {
        let task = makeTask(tags: ["#a"])
        let reminder = makeReminder()

        task.applyToReminder(reminder, addTaskLink: true, vaultPath: "/tmp/Vault", appendLinkToNotes: true)
        reminder.notes = (reminder.notes ?? "") + "\nmine"
        task.applyToReminder(reminder, addTaskLink: true, vaultPath: "/tmp/Vault", appendLinkToNotes: true)

        XCTAssertEqual(
            reminder.notes,
            "Tags: #a\nobsidian://open?vault=Vault&file=Work.md\nmine"
        )

        task.applyToReminder(reminder, addTaskLink: true, vaultPath: "/tmp/Vault", appendLinkToNotes: false)
        XCTAssertEqual(reminder.notes, "Tags: #a\nmine")
    }

    /// #104: the `Tags:` line can be switched off; the old one must then go away.
    func test_104_tagsLineCanBeSwitchedOff() {
        let reminder = makeReminder(notes: "Tags: #a\nmine")
        makeTask(tags: ["#a"]).applyToReminder(reminder, writeTagsToNotes: false)
        XCTAssertEqual(reminder.notes, "mine")

        let empty = makeReminder(notes: "Tags: #a")
        makeTask(tags: ["#a"]).applyToReminder(empty, writeTagsToNotes: false)
        XCTAssertNil(empty.notes)
    }

    // MARK: - Sub-task checklist

    func test_foldedSubtaskChecklistIsReplaced() {
        let reminder = makeReminder(notes: "Tags: #a\n- [ ] old child\nmine")
        makeTask(tags: ["#a"], subtaskSummary: "- [x] new child").applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Tags: #a\n- [x] new child\nmine")
    }

    /// Without folded sub-tasks, a checklist in the notes is the user's.
    func test_userChecklistIsKeptWhenSubtasksAreNotFolded() {
        let reminder = makeReminder(notes: "Tags: #a\n- [ ] milk\n- [ ] eggs")
        makeTask(tags: ["#a"]).applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Tags: #a\n- [ ] milk\n- [ ] eggs")
    }

    // MARK: - Lines that only look generated

    func test_clientLineInsideUserTextIsKept() {
        let reminder = makeReminder(notes: "Tags: #a\nMet with Sam\nClient: Bob from accounts")
        makeTask(tags: ["#a"]).applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Tags: #a\nMet with Sam\nClient: Bob from accounts")
    }

    func test_userClientLineAtTopIsKeptWhenTaskHasNoClient() {
        let reminder = makeReminder(notes: "Client: Bob from accounts\nwants a call")
        makeTask().applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Client: Bob from accounts\nwants a call")
    }

    func test_changedClientReplacesTheOldClientLine() {
        let reminder = makeReminder(notes: "Client: Old Co\nTags: #a\nmine")
        makeTask(tags: ["#a"], clientName: "New Co").applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Client: New Co\nTags: #a\nmine")
    }

    func test_proseStartingWithTagsIsKept() {
        let reminder = makeReminder(notes: "Tags: #a\nTags: still need to decide on these")
        makeTask(tags: ["#a"]).applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Tags: #a\nTags: still need to decide on these")
    }

    // MARK: - Sources that supply their own body (TaskNotes)

    func test_sourceBodyWithoutGeneratedLinesIsUnchanged() {
        let reminder = makeReminder(notes: "stale text in Reminders")
        makeTask(notes: "Body from TaskNotes").applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Body from TaskNotes")
    }

    /// The body used to be dropped whenever a `Tags:` line was written.
    func test_sourceBodyFollowsTheTagsLine() {
        let reminder = makeReminder(notes: "stale text in Reminders")
        makeTask(tags: ["#a"], notes: "Body from TaskNotes").applyToReminder(reminder)
        XCTAssertEqual(reminder.notes, "Tags: #a\nBody from TaskNotes")
    }

    // MARK: - Hash prediction used by the sync engine

    /// The engine hashes `tagsInReminderNotes(reminderNotes(existing:))` as the
    /// reminder's post-sync state. It must match what `fromReminder` reads back,
    /// or a reminder whose notes contain `#3` / `+1 555…` is re-pushed forever.
    func test_predictedTagsMatchWhatTheReminderReportsAfterUpdate() {
        let task = makeTask(tags: ["#errands"])
        let existing = "Tags: #errands\nCall +1 555 0100 about order #3"
        let reminder = makeReminder(notes: existing)

        let predicted = SyncTask.tagsInReminderNotes(task.reminderNotes(existing: existing))
        task.applyToReminder(reminder)
        let reported = SyncTask.fromReminder(reminder, listName: "Errands").tags

        XCTAssertEqual(predicted.sorted(), reported.sorted())
        XCTAssertTrue(reported.contains("#errands"))
    }
}
