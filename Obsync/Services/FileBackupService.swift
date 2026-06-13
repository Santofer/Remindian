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
    private(set) var sessionBackups: [BackupRecord] = []

    private var backupDir: URL? {
        guard let appDir = remindianAppSupportDir() else { return nil }
        return appDir.appendingPathComponent("backups", isDirectory: true)
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

        // Generate backup filename: slugified-relative-path_yyyyMMdd_HHmmss.md
        let slug = fileURL.lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())

        let backupName = "\(slug.replacingOccurrences(of: ".md", with: ""))_\(timestamp).md"
        let backupURL = backupDir.appendingPathComponent(backupName)

        // Skip if already backed up this second (e.g., multiple tasks in same file during one sync)
        if fileManager.fileExists(atPath: backupURL.path) {
            recordSessionBackup(original: fileURL, backup: backupURL)
            return backupURL
        }

        try fileManager.copyItem(at: fileURL, to: backupURL)
        recordSessionBackup(original: fileURL, backup: backupURL)

        // Prune old backups for this file
        pruneBackups(forFileNamed: slug.replacingOccurrences(of: ".md", with: ""))

        return backupURL
    }

    private func recordSessionBackup(original: URL, backup: URL) {
        sessionBackups.append(BackupRecord(originalPath: original.path, backupURL: backup, date: Date()))
        // Bound memory — keep only the most recent entries.
        if sessionBackups.count > 500 {
            sessionBackups.removeFirst(sessionBackups.count - 500)
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
    private func pruneBackups(forFileNamed baseName: String) {
        guard let backupDir = backupDir,
              let contents = try? fileManager.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        // Filter backups for this specific file
        let matching = contents
            .filter { $0.lastPathComponent.hasPrefix(baseName + "_") }
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
