import Foundation

/// Persistent log of sync operations for the History view.
class SyncLog: Codable {
    var entries: [SyncLogEntry] = []
    private static let maxEntries = 200

    struct SyncLogEntry: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let result: SyncResultSummary
        let duration: TimeInterval
        let details: [SyncEngine.SyncLogDetail]

        init(timestamp: Date, result: SyncResultSummary, duration: TimeInterval, details: [SyncEngine.SyncLogDetail]) {
            self.id = UUID()
            self.timestamp = timestamp
            self.result = result
            self.duration = duration
            self.details = details
        }
    }

    struct SyncResultSummary: Codable {
        let created: Int
        let updated: Int
        let deleted: Int
        let completionsWrittenBack: Int
        let errorCount: Int
        let isDryRun: Bool
        let summary: String
    }

    func addEntry(from result: SyncEngine.SyncResult) {
        let summary = SyncResultSummary(
            created: result.created,
            updated: result.updated,
            deleted: result.deleted,
            completionsWrittenBack: result.completionsWrittenBack,
            errorCount: result.errors.count,
            isDryRun: result.isDryRun,
            summary: result.summary
        )
        let entry = SyncLogEntry(
            timestamp: Date(),
            result: summary,
            duration: result.duration,
            details: result.details
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    private static var logURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appFolder = appSupport.appendingPathComponent("Obsync", isDirectory: true)
        try? FileManager.default.createDirectory(at: appFolder, withIntermediateDirectories: true)
        return appFolder.appendingPathComponent("sync_log.json")
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            try data.write(to: Self.logURL)
        } catch {
            print("Failed to save sync log: \(error)")
        }
    }

    static func load() -> SyncLog {
        do {
            let data = try Data(contentsOf: logURL)
            return try JSONDecoder().decode(SyncLog.self, from: data)
        } catch {
            return SyncLog()
        }
    }
}
