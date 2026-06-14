import Foundation

/// Creates timestamped backups of Obsidian files before any modification.
/// Backups are stored in ~/Library/Application Support/Remindian/backups/
class FileBackupService {
    static let shared = FileBackupService()

    private let fileManager = FileManager.default
    private let maxBackupsPerFile = 50
    private let maxBackupAgeDays = 7

    /// A backup taken this app session: the file's original absolute path, the
    /// backup copy, and when it was taken. Drives the "restore vault files" undo
    /// (the backup is the *pre-edit* content, since backups are made before any
    /// writeback). (Diff preview + Undo)
    struct BackupRecord: Equatable {
        let originalPath: String
        let backupURL: URL
        let date: Date
    }

    /// Backups taken during this app session, in order. Used to build a
    /// per-sync undo manifest (the original filename alone can't be reversed to
    /// its full path, so we record the path here at backup time).
    ///
    /// Mutated from the sync engine (off the main actor) AND from main-actor
    /// quick-add/complete flows, so every access is guarded by `backupsLock`.
    private var _sessionBackups: [BackupRecord] = []
    private let backupsLock = NSLock()

    /// Thread-safe snapshot of the session backups taken at/after `date`.
    func sessionBackups(since date: Date) -> [BackupRecord] {
        backupsLock.lock(); defer { backupsLock.unlock() }
        return _sessionBackups.filter { $0.date >= date }
    }

    private var backupDir: URL? {
        guard let appDir = remindianAppSupportDir() else { return nil }
        return appDir.appendingPathComponent("backups", isDirectory: true)
    }

    /// A short, stable (process-independent) hash of a string — used to
    /// disambiguate backups of DIFFERENT files that share a basename (e.g.
    /// `Work/Inbox.md` vs `Personal/Inbox.md`). djb2.
    private func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h))
    }

    /// Create a backup of a file before modifying it.
    /// Returns the backup file URL.
    @discardableResult
    func backupFile(at fileURL: URL) throws -> URL {
        guard let backupDir = backupDir else {
            throw NSError(domain: "FileBackupService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot access application support directory"])
        }
        // Create backup directory if needed
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // Backup filename: <basename>_<timestamp>_<pathHash>.md. The path hash
        // disambiguates two different vault files that share a basename — without
        // it, `Work/Inbox.md` and `Personal/Inbox.md` collided in the same second
        // and the second one's undo record pointed at the first one's content,
        // silently corrupting a note on restore. (audit #2)
        let base = fileURL.lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".md", with: "")
        let pathHash = stableHash(fileURL.path)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())

        let backupName = "\(base)_\(timestamp)_\(pathHash).md"
        let backupURL = backupDir.appendingPathComponent(backupName)

        // Reuse only when an existing backup is genuinely THIS file (same path
        // hash) from the same second — never link a record to another file's copy.
        if fileManager.fileExists(atPath: backupURL.path) {
            recordSessionBackup(original: fileURL, backup: backupURL)
            return backupURL
        }

        try fileManager.copyItem(at: fileURL, to: backupURL)
        recordSessionBackup(original: fileURL, backup: backupURL)

        // Prune old backups for this file (matched by basename + path hash).
        pruneBackups(forFileNamed: base, pathHash: pathHash)

        return backupURL
    }

    private func recordSessionBackup(original: URL, backup: URL) {
        backupsLock.lock(); defer { backupsLock.unlock() }
        _sessionBackups.append(BackupRecord(originalPath: original.path, backupURL: backup, date: Date()))
        // Bound memory — keep only the most recent entries.
        if _sessionBackups.count > 500 {
            _sessionBackups.removeFirst(_sessionBackups.count - 500)
        }
    }

    /// Restore a file from a backup, atomically. Backs up the *current* content
    /// first so the restore is itself reversible. (Diff preview + Undo)
    func restoreFile(from backupURL: URL, to originalPath: String) throws {
        let originalURL = URL(fileURLWithPath: originalPath)
        if fileManager.fileExists(atPath: originalURL.path) {
            _ = try? backupFile(at: originalURL)
        }
        let data = try Data(contentsOf: backupURL)
        try data.write(to: originalURL, options: .atomic)
    }

    /// Remove old backups exceeding limits.
    private func pruneBackups(forFileNamed baseName: String, pathHash: String) {
        guard let backupDir = backupDir,
              let contents = try? fileManager.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        // Filter backups for this specific file (basename prefix + path-hash suffix),
        // so we never prune a *different* same-basename file's backups.
        let matching = contents
            .filter { $0.lastPathComponent.hasPrefix(baseName + "_") && $0.lastPathComponent.hasSuffix("_\(pathHash).md") }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return date1 > date2 // newest first
            }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxBackupAgeDays, to: Date()) ?? Date()

        for (index, url) in matching.enumerated() {
            let creationDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast

            // Keep if within max count AND within age limit
            if index >= maxBackupsPerFile && creationDate < cutoffDate {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Get the backup directory URL (for UI "View Backups" button).
    var backupDirectoryURL: URL? {
        return backupDir
    }
}
