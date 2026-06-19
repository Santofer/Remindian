import Foundation

/// Calendar Feed (.ics) destination.
///
/// Generates a subscribable iCalendar (.ics) file from synced tasks.
/// Tasks become VTODO entries (RFC 5545) with due dates, priorities, and completion status.
/// The .ics file is written to a configurable local path and can be served via any
/// HTTP server, cloud sync folder, or subscribed to directly as a local file.
///
/// Architecture:
/// - AUTH: None required (local file generation)
/// - READ: Reads previously generated .ics to track existing task IDs
/// - CREATE: Adds VTODO entry to the .ics file
/// - UPDATE: Replaces VTODO entry with matching UID
/// - DELETE: Removes VTODO entry
/// - EXPORT: Full .ics regeneration on each sync cycle
class CalendarFeedDestination: TaskDestination {
    let destinationName = "Calendar Feed (.ics)"

    /// Path to the output .ics file (absolute)
    var outputPath: String = ""

    /// Calendar name embedded in the .ics
    var calendarName: String = "Remindian Tasks"

    // In-memory task store (rebuilt from .ics on each sync)
    private var tasks: [String: ICSTask] = [:]
    private var lastGenerated: Date?

    // MARK: - Authorization

    func requestAccess() async throws -> Bool {
        // No auth needed — just verify we can write to the output path
        guard !outputPath.isEmpty else {
            throw CalendarFeedError.noOutputPath
        }
        let dir = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) || !isDir.boolValue {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return true
    }

    // MARK: - Fetching

    func fetchAllTasks() async throws -> [SyncTask] {
        guard !outputPath.isEmpty, FileManager.default.fileExists(atPath: outputPath) else {
            return []
        }

        let content = try String(contentsOfFile: outputPath, encoding: .utf8)
        let parsed = parseICS(content)
        // The .ics file is externally writable (HTTP/cloud-sync folder), so a
        // cloud-sync merge, copy-paste, or interrupted write can leave two VTODOs
        // sharing a UID. `Dictionary(uniqueKeysWithValues:)` would trap on the
        // duplicate key (EXC_BREAKPOINT, the #80 crash class) — merge instead.
        tasks = Dictionary(parsed.map { ($0.uid, $0) }, uniquingKeysWith: { _, latest in latest })
        return parsed.map { $0.toSyncTask() }
    }

    func getAvailableLists() async -> [String] {
        // Calendar feed is a single output — no list concept
        return [calendarName]
    }

    // MARK: - CRUD

    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        let uid = "remindian-\(UUID().uuidString)"
        let icsTask = ICSTask.from(task, uid: uid, listName: listName)
        tasks[uid] = icsTask
        try writeICS()
        debugLog("[CalendarFeed] Created VTODO \(uid) for \"\(task.title)\"")
        return uid
    }

    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        guard tasks[id] != nil else {
            throw CalendarFeedError.taskNotFound(id)
        }
        let listName = tasks[id]?.categories ?? calendarName
        tasks[id] = ICSTask.from(task, uid: id, listName: listName)
        try writeICS()
    }

    func moveTask(withId id: String, toList listName: String) async throws {
        guard var icsTask = tasks[id] else {
            throw CalendarFeedError.taskNotFound(id)
        }
        icsTask.categories = listName
        tasks[id] = icsTask
        try writeICS()
    }

    func deleteTask(withId id: String) async throws {
        tasks.removeValue(forKey: id)
        try writeICS()
    }

    func refresh() {
        tasks.removeAll()
        lastGenerated = nil
    }

    // MARK: - ICS Generation

    private func writeICS() throws {
        guard !outputPath.isEmpty else {
            throw CalendarFeedError.noOutputPath
        }

        var lines: [String] = []
        lines.append("BEGIN:VCALENDAR")
        lines.append("VERSION:2.0")
        lines.append("PRODID:-//Remindian//Calendar Feed//EN")
        lines.append("X-WR-CALNAME:\(calendarName)")
        lines.append("METHOD:PUBLISH")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        for (_, task) in tasks.sorted(by: { $0.key < $1.key }) {
            lines.append("BEGIN:VTODO")
            lines.append("UID:\(task.uid)")
            lines.append("DTSTAMP:\(formatter.string(from: Date()))")
            lines.append("SUMMARY:\(escapeICS(task.summary))")

            if let due = task.due {
                // All-day: VALUE=DATE format (YYYYMMDD)
                let dayFormatter = DateFormatter()
                dayFormatter.dateFormat = "yyyyMMdd"
                lines.append("DUE;VALUE=DATE:\(dayFormatter.string(from: due))")
            }

            if let start = task.start {
                let dayFormatter = DateFormatter()
                dayFormatter.dateFormat = "yyyyMMdd"
                lines.append("DTSTART;VALUE=DATE:\(dayFormatter.string(from: start))")
            }

            if task.priority > 0 {
                lines.append("PRIORITY:\(task.priority)")
            }

            if task.isCompleted {
                lines.append("STATUS:COMPLETED")
                if let completed = task.completedDate {
                    lines.append("COMPLETED:\(formatter.string(from: completed))")
                }
                lines.append("PERCENT-COMPLETE:100")
            } else {
                lines.append("STATUS:NEEDS-ACTION")
            }

            if !task.categories.isEmpty {
                lines.append("CATEGORIES:\(escapeICS(task.categories))")
            }

            if let description = task.description, !description.isEmpty {
                lines.append("DESCRIPTION:\(escapeICS(description))")
            }

            lines.append("END:VTODO")
        }

        lines.append("END:VCALENDAR")

        let content = lines.joined(separator: "\r\n") + "\r\n"
        try content.write(toFile: outputPath, atomically: true, encoding: .utf8)
        lastGenerated = Date()
        debugLog("[CalendarFeed] Wrote \(tasks.count) VTODOs to \(outputPath)")
    }

    // MARK: - ICS Parsing

    private func parseICS(_ content: String) -> [ICSTask] {
        var results: [ICSTask] = []
        let lines = content.components(separatedBy: .newlines)

        var inTodo = false
        var uid = ""
        var summary = ""
        var due: Date?
        var start: Date?
        var priority = 0
        var isCompleted = false
        var completedDate: Date?
        var categories = ""
        var description: String?

        let dayParser = DateFormatter()
        dayParser.dateFormat = "yyyyMMdd"
        let isoParser = ISO8601DateFormatter()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed == "BEGIN:VTODO" {
                inTodo = true
                uid = ""; summary = ""; due = nil; start = nil
                priority = 0; isCompleted = false; completedDate = nil
                categories = ""; description = nil
            } else if trimmed == "END:VTODO" && inTodo {
                if !uid.isEmpty {
                    results.append(ICSTask(
                        uid: uid, summary: summary, due: due, start: start,
                        priority: priority, isCompleted: isCompleted,
                        completedDate: completedDate, categories: categories,
                        description: description
                    ))
                }
                inTodo = false
            } else if inTodo {
                if trimmed.hasPrefix("UID:") {
                    uid = String(trimmed.dropFirst(4))
                } else if trimmed.hasPrefix("SUMMARY:") {
                    summary = unescapeICS(String(trimmed.dropFirst(8)))
                } else if trimmed.hasPrefix("DUE;VALUE=DATE:") {
                    due = dayParser.date(from: String(trimmed.dropFirst(15)))
                } else if trimmed.hasPrefix("DUE:") {
                    due = isoParser.date(from: String(trimmed.dropFirst(4)))
                        ?? dayParser.date(from: String(trimmed.dropFirst(4)))
                } else if trimmed.hasPrefix("DTSTART;VALUE=DATE:") {
                    start = dayParser.date(from: String(trimmed.dropFirst(19)))
                } else if trimmed.hasPrefix("DTSTART:") {
                    start = isoParser.date(from: String(trimmed.dropFirst(8)))
                } else if trimmed.hasPrefix("PRIORITY:") {
                    priority = Int(trimmed.dropFirst(9)) ?? 0
                } else if trimmed.hasPrefix("STATUS:COMPLETED") {
                    isCompleted = true
                } else if trimmed.hasPrefix("COMPLETED:") {
                    completedDate = isoParser.date(from: String(trimmed.dropFirst(10)))
                } else if trimmed.hasPrefix("CATEGORIES:") {
                    categories = unescapeICS(String(trimmed.dropFirst(11)))
                } else if trimmed.hasPrefix("DESCRIPTION:") {
                    description = unescapeICS(String(trimmed.dropFirst(12)))
                }
            }
        }

        return results
    }

    // MARK: - Helpers

    private func escapeICS(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func unescapeICS(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

// MARK: - Internal Model

private struct ICSTask {
    let uid: String
    var summary: String
    var due: Date?
    var start: Date?
    var priority: Int  // iCalendar: 1=high, 5=medium, 9=low, 0=undefined
    var isCompleted: Bool
    var completedDate: Date?
    var categories: String
    var description: String?

    func toSyncTask() -> SyncTask {
        let syncPriority: SyncTask.Priority = {
            switch priority {
            case 1...4: return .high
            case 5: return .medium
            case 6...9: return .low
            default: return .none
            }
        }()

        return SyncTask(
            title: summary,
            isCompleted: isCompleted,
            priority: syncPriority,
            dueDate: due,
            startDate: start,
            completedDate: completedDate,
            tags: categories.isEmpty ? [] : categories.split(separator: ",").map { "#\($0.trimmingCharacters(in: .whitespaces))" },
            targetList: categories.isEmpty ? nil : categories,
            notes: description,
            remindersId: uid,
            lastModified: Date()
        )
    }

    static func from(_ task: SyncTask, uid: String, listName: String) -> ICSTask {
        let icsPriority: Int = {
            switch task.priority {
            case .high: return 1
            case .medium: return 5
            case .low: return 9
            case .none: return 0
            }
        }()

        return ICSTask(
            uid: uid,
            summary: task.title,
            due: task.dueDate,
            start: task.startDate,
            priority: icsPriority,
            isCompleted: task.isCompleted,
            completedDate: task.completedDate,
            categories: listName,
            description: task.notes
        )
    }
}

// MARK: - Errors

enum CalendarFeedError: LocalizedError {
    case noOutputPath
    case taskNotFound(String)
    case writeError(String)

    var errorDescription: String? {
        switch self {
        case .noOutputPath:
            return "No output path configured for the calendar feed. Set a path in Settings > General."
        case .taskNotFound(let id):
            return "Calendar feed task not found: \(id)"
        case .writeError(let detail):
            return "Failed to write calendar feed: \(detail)"
        }
    }
}
