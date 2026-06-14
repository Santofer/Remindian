import XCTest
@testable import Remindian

/// Tests for the backup/restore that powers "Undo last sync" (v5.17.0).
///
/// The invariant: a backup taken before an edit captures the pre-edit content,
/// and `restoreFile` returns the file to exactly that content — atomically, and
/// only after backing up the *current* content so the undo is itself reversible.
final class FileBackupRestoreTests: XCTestCase {

    private var dir: URL!
    /// Unique per-test stem. FileBackupService keys backups by filename + second
    /// in a shared dir, so distinct test files must have distinct names to avoid
    /// cross-test collisions (a same-name same-second backup is skipped).
    private var stem: String!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("remindian-backup-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stem = "bk-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    func test_backupThenRestore_returnsPreEditContent() throws {
        let file = dir.appendingPathComponent("\(stem!)-note.md")
        try "- [ ] Original\n".write(to: file, atomically: true, encoding: .utf8)

        // Back up (pre-edit), then mutate the file.
        let backup = try FileBackupService.shared.backupFile(at: file)
        try "- [x] Edited by sync ✅ 2025-01-01\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "- [x] Edited by sync ✅ 2025-01-01\n")

        // Restore → back to the pre-edit content.
        try FileBackupService.shared.restoreFile(from: backup, to: file.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "- [ ] Original\n", "Restore must reproduce the pre-edit content.")
    }

    func test_restore_backsUpCurrentContentFirst() throws {
        let file = dir.appendingPathComponent("\(stem!)-note2.md")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        let backupV1 = try FileBackupService.shared.backupFile(at: file)
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)

        let beforeRestoreCount = FileBackupService.shared.sessionBackups(since: .distantPast).count
        try FileBackupService.shared.restoreFile(from: backupV1, to: file.path)

        // restoreFile must have backed up the current ("v2") content first, so a
        // record was appended — the undo is itself reversible.
        XCTAssertGreaterThan(FileBackupService.shared.sessionBackups(since: .distantPast).count, beforeRestoreCount,
                             "Restoring should back up the current content first.")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "v1\n")
    }

    func test_sessionBackup_recordsOriginalPath() throws {
        let file = dir.appendingPathComponent("\(stem!)-tracked.md")
        try "content\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try FileBackupService.shared.backupFile(at: file)
        XCTAssertTrue(FileBackupService.shared.sessionBackups(since: .distantPast).contains { $0.originalPath == file.path },
                      "The backup manifest must record the file's original absolute path so undo can target it.")
    }

    // MARK: - audit #2: same-basename files must not collide on restore

    func test_sameBasenameDifferentFolders_doNotCorruptEachOther() throws {
        // Two different files sharing a basename ("Inbox.md"), backed up in the
        // same window. Each must restore its OWN pre-edit content — never the
        // other's. (Regression for the Work/Inbox.md ↔ Personal/Inbox.md bug.)
        let workDir = dir.appendingPathComponent("Work"); let persoDir = dir.appendingPathComponent("Personal")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: persoDir, withIntermediateDirectories: true)
        let work = workDir.appendingPathComponent("Inbox.md")
        let perso = persoDir.appendingPathComponent("Inbox.md")
        try "WORK original\n".write(to: work, atomically: true, encoding: .utf8)
        try "PERSO original\n".write(to: perso, atomically: true, encoding: .utf8)

        let workBackup = try FileBackupService.shared.backupFile(at: work)
        let persoBackup = try FileBackupService.shared.backupFile(at: perso)
        XCTAssertNotEqual(workBackup, persoBackup, "Same-basename files must get distinct backups.")

        // Mutate both, then restore each from its own backup.
        try "WORK edited\n".write(to: work, atomically: true, encoding: .utf8)
        try "PERSO edited\n".write(to: perso, atomically: true, encoding: .utf8)
        try FileBackupService.shared.restoreFile(from: workBackup, to: work.path)
        try FileBackupService.shared.restoreFile(from: persoBackup, to: perso.path)

        XCTAssertEqual(try String(contentsOf: work, encoding: .utf8), "WORK original\n")
        XCTAssertEqual(try String(contentsOf: perso, encoding: .utf8), "PERSO original\n", "Personal/Inbox.md must NOT be overwritten with Work/Inbox.md content.")
    }
}
