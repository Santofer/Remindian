import XCTest
@testable import Remindian

/// Tests for the backup/restore that powers "Undo last sync" (v5.17.0).
///
/// The invariant: a backup taken before an edit captures the pre-edit content,
/// and `restoreFile` returns the file to exactly that content — atomically, and
/// only after backing up the *current* content so the undo is itself reversible.
final class FileBackupRestoreTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("remindian-backup-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    func test_backupThenRestore_returnsPreEditContent() throws {
        let file = dir.appendingPathComponent("note.md")
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
        let file = dir.appendingPathComponent("note2.md")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        let backupV1 = try FileBackupService.shared.backupFile(at: file)
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)

        let beforeRestoreCount = FileBackupService.shared.sessionBackups.count
        try FileBackupService.shared.restoreFile(from: backupV1, to: file.path)

        // restoreFile must have backed up the current ("v2") content first, so a
        // record was appended — the undo is itself reversible.
        XCTAssertGreaterThan(FileBackupService.shared.sessionBackups.count, beforeRestoreCount,
                             "Restoring should back up the current content first.")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "v1\n")
    }

    func test_sessionBackup_recordsOriginalPath() throws {
        let file = dir.appendingPathComponent("tracked.md")
        try "content\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try FileBackupService.shared.backupFile(at: file)
        XCTAssertTrue(FileBackupService.shared.sessionBackups.contains { $0.originalPath == file.path },
                      "The backup manifest must record the file's original absolute path so undo can target it.")
    }
}
