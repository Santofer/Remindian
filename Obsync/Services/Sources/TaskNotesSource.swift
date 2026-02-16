import Foundation

/// TaskNotes source — reads tasks from the TaskNotes plugin's file-based format.
///
/// TaskNotes stores each task as a separate .md file with YAML frontmatter:
/// ```
/// ---
/// status: todo
/// priority: medium
/// due: 2026-03-15
/// recurrence: RRULE:FREQ=MONTHLY;BYMONTHDAY=20
/// tags: [work, urgent]
/// created: 2026-01-01T10:00:00
/// ---
/// # Task Title
///
/// Task description/notes here
/// ```
///
/// Integration methods:
/// 1. File-based: Read/write .md files in TaskNotes/Tasks/ directory (works without Obsidian open)
/// 2. HTTP API: GET/POST/PUT/DELETE /api/tasks (requires Obsidian open with TaskNotes plugin)
/// 3. Webhooks: TaskNotes can send events on task changes (for reactive sync)
class TaskNotesSource: TaskSource {
    let sourceName = "TaskNotes"

    private let fileManager = FileManager.default
    private let backupService = FileBackupService.shared
    private let auditLog = AuditLog.shared

    /// Whether to use the HTTP API (true) or file-based access (false).
    /// File-based is more reliable but HTTP API provides richer metadata.
    var useHttpApi: Bool = false

    /// HTTP API base URL (default: TaskNotes plugin local server)
    var apiBaseUrl: String = "http://localhost:7117"

    // MARK: - Task Scanning

    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] {
        if useHttpApi {
            return try scanTasksViaApi()
        } else {
            return try scanTasksFromFiles(config: config)
        }
    }

    func generateTaskId(for task: SyncTask) -> String {
        // TaskNotes uses file-based tasks, so the file path IS the unique ID
        guard let source = task.obsidianSource else {
            let components = [task.title, task.targetList ?? ""]
            return "tasknotes|\(components.joined(separator: "|").data(using: .utf8)!.base64EncodedString())"
        }
        return "tasknotes|\(source.filePath)"
    }

    // MARK: - Writeback

    @discardableResult
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }

        let fileURL = URL(fileURLWithPath: config.vaultPath + source.filePath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ObsidianError.fileNotFound(fileURL.path)
        }

        try backupService.backupFile(at: fileURL)

        var content = try String(contentsOf: fileURL, encoding: .utf8)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let dateStr = formatter.string(from: completionDate)

        // Update status in frontmatter
        content = updateFrontmatterField(in: content, field: "status", value: "done")
        content = updateFrontmatterField(in: content, field: "completed", value: dateStr)

        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        auditLog.logFileModification(
            action: "taskNotesComplete",
            filePath: source.filePath,
            lineNumber: 0,
            beforeLine: "status: todo",
            afterLine: "status: done"
        )

        return 0
    }

    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }

        let fileURL = URL(fileURLWithPath: config.vaultPath + source.filePath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ObsidianError.fileNotFound(fileURL.path)
        }

        try backupService.backupFile(at: fileURL)

        var content = try String(contentsOf: fileURL, encoding: .utf8)
        content = updateFrontmatterField(in: content, field: "status", value: "todo")
        content = removeFrontmatterField(in: content, field: "completed")

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }

        let fileURL = URL(fileURLWithPath: config.vaultPath + source.filePath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ObsidianError.fileNotFound(fileURL.path)
        }

        try backupService.backupFile(at: fileURL)

        var content = try String(contentsOf: fileURL, encoding: .utf8)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        if let dueDateChange = changes.newDueDate {
            if let date = dueDateChange {
                content = updateFrontmatterField(in: content, field: "due", value: dateFormatter.string(from: date))
            } else {
                content = removeFrontmatterField(in: content, field: "due")
            }
        }

        if let startDateChange = changes.newStartDate {
            if let date = startDateChange {
                content = updateFrontmatterField(in: content, field: "start", value: dateFormatter.string(from: date))
            } else {
                content = removeFrontmatterField(in: content, field: "start")
            }
        }

        if let newPriority = changes.newPriority {
            let priorityStr: String
            switch newPriority {
            case .high: priorityStr = "high"
            case .medium: priorityStr = "medium"
            case .low: priorityStr = "low"
            case .none: priorityStr = "none"
            }
            content = updateFrontmatterField(in: content, field: "priority", value: priorityStr)
        }

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        // TaskNotes creates a new file for each task
        let tasksDir = config.taskNotesFolder.isEmpty ? "TaskNotes/Tasks" : config.taskNotesFolder
        let dirURL = URL(fileURLWithPath: config.vaultPath).appendingPathComponent(tasksDir)

        if !fileManager.fileExists(atPath: dirURL.path) {
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        // Generate filename from title
        let sanitizedTitle = task.title
            .replacingOccurrences(of: "[^a-zA-Z0-9\\s-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .prefix(50)
        let fileName = "\(sanitizedTitle)-\(UUID().uuidString.prefix(8)).md"
        let fileURL = dirURL.appendingPathComponent(String(fileName))

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        // Build YAML frontmatter
        var frontmatter = "---\n"
        frontmatter += "status: \(task.isCompleted ? "done" : "todo")\n"

        if task.priority != .none {
            let priorityStr: String
            switch task.priority {
            case .high: priorityStr = "high"
            case .medium: priorityStr = "medium"
            case .low: priorityStr = "low"
            case .none: priorityStr = "none"
            }
            frontmatter += "priority: \(priorityStr)\n"
        }

        if let dueDate = task.dueDate {
            frontmatter += "due: \(dateFormatter.string(from: dueDate))\n"
        }

        if let startDate = task.startDate {
            frontmatter += "start: \(dateFormatter.string(from: startDate))\n"
        }

        if !task.tags.isEmpty {
            let tagNames = task.tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            frontmatter += "tags: [\(tagNames.joined(separator: ", "))]\n"
        }

        frontmatter += "created: \(isoFormatter.string(from: Date()))\n"

        if task.isCompleted, let completedDate = task.completedDate {
            frontmatter += "completed: \(isoFormatter.string(from: completedDate))\n"
        }

        frontmatter += "---\n"

        // Build content
        var content = frontmatter
        content += "# \(task.title)\n"
        if let notes = task.notes, !notes.isEmpty {
            content += "\n\(notes)\n"
        }

        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let relativePath = "/" + tasksDir + "/" + String(fileName)
        return SyncTask.ObsidianSource(
            filePath: relativePath,
            lineNumber: 1,
            originalLine: "# \(task.title)"
        )
    }

    func hasFileChanged(task: SyncTask, since timestamp: Date, config: SyncConfiguration) -> Bool {
        guard let source = task.obsidianSource else { return true }
        let fileURL = URL(fileURLWithPath: config.vaultPath + source.filePath)
        guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return true
        }
        return modDate > timestamp
    }

    // MARK: - File-Based Scanning

    private func scanTasksFromFiles(config: SyncConfiguration) throws -> [SyncTask] {
        let tasksDir = config.taskNotesFolder.isEmpty ? "TaskNotes/Tasks" : config.taskNotesFolder
        let dirURL = URL(fileURLWithPath: config.vaultPath).appendingPathComponent(tasksDir)

        guard fileManager.fileExists(atPath: dirURL.path) else {
            debugLog("[TaskNotes] Tasks directory not found: \(dirURL.path)")
            return []
        }

        var tasks: [SyncTask] = []
        let files = try fileManager.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil)

        for fileURL in files where fileURL.pathExtension.lowercased() == "md" {
            if let task = try? parseTaskNotesFile(fileURL, vaultPath: config.vaultPath) {
                tasks.append(task)
            }
        }

        debugLog("[TaskNotes] Found \(tasks.count) tasks in \(tasksDir)")
        return tasks
    }

    /// Parse a single TaskNotes .md file into a SyncTask.
    private func parseTaskNotesFile(_ fileURL: URL, vaultPath: String) throws -> SyncTask {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let relativePath = fileURL.path.replacingOccurrences(of: vaultPath, with: "")

        // Parse YAML frontmatter
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw TaskNotesError.noFrontmatter(fileURL.lastPathComponent)
        }

        var status = "todo"
        var priority: SyncTask.Priority = .none
        var dueDate: Date?
        var startDate: Date?
        var completedDate: Date?
        var tags: [String] = []
        var title = fileURL.deletingPathExtension().lastPathComponent

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        var inFrontmatter = false
        var frontmatterEnded = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "---" {
                if !inFrontmatter {
                    inFrontmatter = true
                    continue
                } else {
                    frontmatterEnded = true
                    continue
                }
            }

            if inFrontmatter && !frontmatterEnded {
                // Parse YAML fields
                if let colonIndex = trimmed.firstIndex(of: ":") {
                    let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

                    switch key {
                    case "status":
                        status = value
                    case "priority":
                        switch value.lowercased() {
                        case "high": priority = .high
                        case "medium": priority = .medium
                        case "low": priority = .low
                        default: priority = .none
                        }
                    case "due":
                        dueDate = dateFormatter.date(from: value)
                    case "start":
                        startDate = dateFormatter.date(from: value)
                    case "completed":
                        completedDate = isoFormatter.date(from: value) ?? dateFormatter.date(from: value)
                    case "tags":
                        // Parse YAML array: [tag1, tag2] or - tag1
                        let cleaned = value
                            .replacingOccurrences(of: "[", with: "")
                            .replacingOccurrences(of: "]", with: "")
                        tags = cleaned.components(separatedBy: ",").map { "#\($0.trimmingCharacters(in: .whitespaces))" }
                    default:
                        break
                    }
                }
            }

            // Parse title from first heading after frontmatter
            if frontmatterEnded && trimmed.hasPrefix("# ") {
                title = String(trimmed.dropFirst(2))
            }
        }

        let isCompleted = status == "done" || status == "completed" || status == "cancelled"
        let targetList = tags.first.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }

        return SyncTask(
            title: title,
            isCompleted: isCompleted,
            priority: priority,
            dueDate: dueDate,
            startDate: startDate,
            completedDate: completedDate,
            tags: tags,
            targetList: targetList,
            obsidianSource: SyncTask.ObsidianSource(
                filePath: relativePath,
                lineNumber: 1,
                originalLine: "# \(title)"
            ),
            lastModified: completedDate ?? Date()
        )
    }

    // MARK: - HTTP API

    private func scanTasksViaApi() throws -> [SyncTask] {
        guard let url = URL(string: "\(apiBaseUrl)/api/tasks") else {
            throw TaskNotesError.invalidApiUrl
        }

        // Synchronous request (we're already on a background thread during sync)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = responseError {
            throw TaskNotesError.apiError(error.localizedDescription)
        }

        guard let data = responseData else {
            throw TaskNotesError.apiError("No data received")
        }

        // Parse JSON response
        let decoder = JSONDecoder()
        let apiTasks = try decoder.decode([TaskNotesApiTask].self, from: data)
        return apiTasks.map { $0.toSyncTask() }
    }

    // MARK: - Frontmatter Helpers

    private func updateFrontmatterField(in content: String, field: String, value: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var inFrontmatter = false
        var fieldFound = false

        for i in 0..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                if !inFrontmatter {
                    inFrontmatter = true
                    continue
                } else {
                    // End of frontmatter — insert field before closing if not found
                    if !fieldFound {
                        lines.insert("\(field): \(value)", at: i)
                    }
                    break
                }
            }
            if inFrontmatter && trimmed.lowercased().hasPrefix("\(field):") {
                lines[i] = "\(field): \(value)"
                fieldFound = true
            }
        }

        return lines.joined(separator: "\n")
    }

    private func removeFrontmatterField(in content: String, field: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var inFrontmatter = false

        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                inFrontmatter = !inFrontmatter
                return false
            }
            if inFrontmatter && trimmed.lowercased().hasPrefix("\(field):") {
                return true
            }
            return false
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - API Response Models

private struct TaskNotesApiTask: Codable {
    let id: String?
    let title: String
    let status: String?
    let priority: String?
    let due: String?
    let start: String?
    let completed: String?
    let tags: [String]?
    let notes: String?
    let filePath: String?

    func toSyncTask() -> SyncTask {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let isCompleted = status == "done" || status == "completed"
        let taskPriority: SyncTask.Priority
        switch priority?.lowercased() {
        case "high": taskPriority = .high
        case "medium": taskPriority = .medium
        case "low": taskPriority = .low
        default: taskPriority = .none
        }

        let taskTags = (tags ?? []).map { "#\($0)" }

        return SyncTask(
            title: title,
            isCompleted: isCompleted,
            priority: taskPriority,
            dueDate: due.flatMap { dateFormatter.date(from: $0) },
            startDate: start.flatMap { dateFormatter.date(from: $0) },
            completedDate: completed.flatMap { dateFormatter.date(from: $0) },
            tags: taskTags,
            targetList: taskTags.first.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 },
            notes: notes,
            obsidianSource: filePath.map { SyncTask.ObsidianSource(filePath: $0, lineNumber: 1, originalLine: "# \(title)") },
            remindersId: id
        )
    }
}

// MARK: - Errors

enum TaskNotesError: LocalizedError {
    case noFrontmatter(String)
    case invalidApiUrl
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .noFrontmatter(let file):
            return "TaskNotes file has no YAML frontmatter: \(file)"
        case .invalidApiUrl:
            return "Invalid TaskNotes API URL"
        case .apiError(let message):
            return "TaskNotes API error: \(message)"
        }
    }
}
