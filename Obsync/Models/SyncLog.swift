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

    private static var logURL: URL? {
        guard let appFolder = remindianAppSupportDir() else { return nil }
        return appFolder.appendingPathComponent("sync_log.json")
    }

    func save() {
        guard let url = Self.logURL else { return }
        do {
            let data = try JSONEncoder().encode(self)
            try SecureFile.write(data, to: url)
        } catch {
            print("Failed to save sync log: \(error)")
        }
    }

    static func load() -> SyncLog {
        guard let url = logURL else { return SyncLog() }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(SyncLog.self, from: data)
        } catch {
            return SyncLog()
        }
    }
}
