import Foundation

/// Creates timestamped backups of Obsidian files before any modification.
/// Backups are stored in ~/Library/Application Support/Obsync/backups/
class FileBackupService {
    static let shared = FileBackupService()

    private let fileManager = FileManager.default
    private let maxBackupsPerFile = 50
    private let maxBackupAgeDays = 7

    private var backupDir: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Obsync", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
    }

    /// Create a backup of a file before modifying it.
    /// Returns the backup file URL.
    @discardableResult
    func backupFile(at fileURL: URL) throws -> URL {
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

        try fileManager.copyItem(at: fileURL, to: backupURL)

        // Prune old backups for this file
        pruneBackups(forFileNamed: slug.replacingOccurrences(of: ".md", with: ""))

        return backupURL
    }

    /// Remove old backups exceeding limits.
    private func pruneBackups(forFileNamed baseName: String) {
        guard let contents = try? fileManager.contentsOfDirectory(
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
    var backupDirectoryURL: URL {
        return backupDir
    }
}
