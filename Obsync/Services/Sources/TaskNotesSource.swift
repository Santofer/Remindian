import Foundation

/// TaskNotes source — reads tasks from the TaskNotes/mdbase-tasknotes ecosystem.
///
/// TaskNotes stores each task as a separate .md file with YAML frontmatter:
/// ```
/// ---
/// title: Buy groceries
/// status: open
/// priority: normal
/// due: 2026-03-15
/// scheduled: 2026-03-14
/// tags: [work, urgent]
/// dateCreated: 2026-01-01
/// ---
///
/// Task description/notes here
/// ```
///
/// Integration methods (in priority order):
/// 1. CLI (`mtn`): Uses `mdbase-tasknotes` CLI — works without Obsidian open.
///    Install: `npm install -g mdbase-tasknotes`
/// 2. File-based: Direct read/write of .md files in the tasks directory.
/// 3. HTTP API: GET/POST/PUT/DELETE /api/tasks (requires Obsidian open with TaskNotes plugin)
class TaskNotesSource: TaskSource {
    let sourceName = "TaskNotes"

    private let fileManager = FileManager.default
    private let backupService = FileBackupService.shared
    private let auditLog = AuditLog.shared

    /// Integration mode for TaskNotes.
    enum IntegrationMode: String, Codable, CaseIterable {
        case cli = "cli"           // mtn CLI (standalone, recommended)
        case fileBased = "file"    // Direct file read/write
        case httpApi = "http"      // HTTP API (requires Obsidian)

        var displayName: String {
            switch self {
            case .cli: return "CLI (mtn)"
            case .fileBased: return "Direct Files"
            case .httpApi: return "HTTP API"
            }
        }

        var description: String {
            switch self {
            case .cli: return "Uses mdbase-tasknotes CLI. Works without Obsidian. Install: npm install -g mdbase-tasknotes"
            case .fileBased: return "Reads/writes task files directly. Works without Obsidian."
            case .httpApi: return "Uses the TaskNotes plugin HTTP API. Requires Obsidian to be open."
            }
        }
    }

    /// Current integration mode
    var integrationMode: IntegrationMode = .cli

    /// HTTP API base URL (default: TaskNotes plugin local server)
    var apiBaseUrl: String = "http://localhost:8080"

    /// Path to the mtn binary (user-configured via file picker for sandbox access)
    var mtnPath: String = ""

    // MARK: - CLI Detection & Sandbox Bookmark

    /// Resolve the saved security-scoped bookmark for the mtn binary.
    /// Must be called on app launch to restore sandbox access to the CLI tool.
    static func resolveMtnBookmark() -> String? {
        guard let data = UserDefaults.standard.data(forKey: "mtnBinaryBookmark") else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            debugLog("[TaskNotes] Failed to resolve mtn bookmark")
            return nil
        }
        if isStale {
            debugLog("[TaskNotes] mtn bookmark is stale")
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            debugLog("[TaskNotes] Failed to start accessing mtn binary")
            return nil
        }
        debugLog("[TaskNotes] Resolved mtn bookmark: \(url.path)")
        return url.path
    }

    /// Save a security-scoped bookmark for the mtn binary path.
    /// Called after user selects the binary via NSOpenPanel.
    static func saveMtnBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: "mtnBinaryBookmark")
            debugLog("[TaskNotes] Saved mtn bookmark for: \(url.path)")
        } catch {
            debugLog("[TaskNotes] Failed to save mtn bookmark: \(error)")
        }
    }

    /// Check if mtn is available (user-configured path, bookmark, or shell fallback)
    var isMtnAvailable: Bool {
        return effectiveMtnPath != nil
    }

    /// Get the effective mtn path. Priority:
    /// 1. User-configured path (from settings)
    /// 2. Saved bookmark path
    /// 3. Shell-based detection (runs in non-sandboxed /bin/sh)
    private var effectiveMtnPath: String? {
        // 1. User-configured path
        if !mtnPath.isEmpty && fileManager.isExecutableFile(atPath: mtnPath) {
            return mtnPath
        }

        // 2. Try resolved bookmark
        if let bookmarkPath = TaskNotesSource.resolveMtnBookmark(),
           fileManager.isExecutableFile(atPath: bookmarkPath) {
            return bookmarkPath
        }

        // 3. Check common paths (may work if app has read access)
        let commonPaths = [
            "/usr/local/bin/mtn",
            "/opt/homebrew/bin/mtn",
            "\(NSHomeDirectory())/.npm-global/bin/mtn"
        ]
        for path in commonPaths {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    // MARK: - CLI Execution Helper

    /// Run an mtn command and return stdout.
    /// Uses /bin/sh -l -c to execute the command, which gives access to the user's
    /// full PATH (including nvm, npm-global, homebrew). This works in the sandbox
    /// because /bin/sh is always accessible.
    private func runMtn(args: [String], collectionPath: String) throws -> String {
        // Build the full command string for shell execution
        let mtnBinary: String

        if let directPath = effectiveMtnPath {
            // Use the direct path if we have sandbox access
            mtnBinary = directPath
        } else {
            // Fall back to just "mtn" and rely on the shell's PATH
            mtnBinary = "mtn"
        }

        // Escape the collection path and args for shell
        let escapedPath = collectionPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedArgs = args.map { $0.replacingOccurrences(of: "'", with: "'\\''") }
        let fullCommand = "'\(mtnBinary)' -p '\(escapedPath)' " + escapedArgs.map { "'\($0)'" }.joined(separator: " ")

        debugLog("[TaskNotes] Running: /bin/sh -l -c \"\(fullCommand)\"")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-l", "-c", fullCommand]

        // Ensure common bin paths are in PATH
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "\(NSHomeDirectory())/.npm-global/bin"]
        if let existingPath = env["PATH"] {
            env["PATH"] = extraPaths.joined(separator: ":") + ":" + existingPath
        } else {
            env["PATH"] = extraPaths.joined(separator: ":") + ":/usr/bin:/bin"
        }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            debugLog("[TaskNotes] mtn error (exit \(process.terminationStatus)): \(errorOutput)")
            throw TaskNotesError.cliError("mtn exited with code \(process.terminationStatus): \(errorOutput)")
        }

        return output
    }

    // MARK: - Task Scanning

    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] {
        switch integrationMode {
        case .cli:
            return try scanTasksViaCli(config: config)
        case .fileBased:
            return try scanTasksFromFiles(config: config)
        case .httpApi:
            return try scanTasksViaApi()
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

    // MARK: - CLI Scanning

    private func scanTasksViaCli(config: SyncConfiguration) throws -> [SyncTask] {
        let collectionPath = resolveCollectionPath(config: config)

        let output = try runMtn(args: ["list", "--json", "--limit", "10000"], collectionPath: collectionPath)

        guard !output.isEmpty else {
            debugLog("[TaskNotes] mtn returned empty output")
            return []
        }

        guard let data = output.data(using: .utf8) else {
            throw TaskNotesError.cliError("Failed to parse mtn output as UTF-8")
        }

        let decoder = JSONDecoder()
        let cliTasks = try decoder.decode([MtnCliTask].self, from: data)
        let tasks = cliTasks.map { $0.toSyncTask() }

        debugLog("[TaskNotes] CLI found \(tasks.count) tasks")
        return tasks
    }

    // MARK: - CLI Writeback

    @discardableResult
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }

        if integrationMode == .cli, effectiveMtnPath != nil {
            return try markTaskCompleteViaCli(task: task, config: config)
        }

        // Fallback to file-based
        let fileURL = URL(fileURLWithPath: resolveFullPath(source: source, config: config))
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ObsidianError.fileNotFound(fileURL.path)
        }

        FileWatcherService.shared.registerSelfModification(fileURL.path)
        try backupService.backupFile(at: fileURL)

        var content = try String(contentsOf: fileURL, encoding: .utf8)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let dateStr = formatter.string(from: completionDate)

        content = updateFrontmatterField(in: content, field: "status", value: "done")
        content = updateFrontmatterField(in: content, field: "completedDate", value: dateStr)

        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        auditLog.logFileModification(
            action: "taskNotesComplete",
            filePath: source.filePath,
            lineNumber: 0,
            beforeLine: "status: open",
            afterLine: "status: done"
        )

        return 0
    }

    private func markTaskCompleteViaCli(task: SyncTask, config: SyncConfiguration) throws -> Int {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }

        let fullPath = resolveFullPath(source: source, config: config)
        FileWatcherService.shared.registerSelfModification(fullPath)

        let collectionPath = resolveCollectionPath(config: config)
        _ = try runMtn(args: ["complete", source.filePath], collectionPath: collectionPath)

        auditLog.logFileModification(
            action: "taskNotesComplete",
            filePath: source.filePath,
            lineNumber: 0,
            beforeLine: "status: open",
            afterLine: "status: done"
        )

        return 0
    }

    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }

        if integrationMode == .cli, effectiveMtnPath != nil {
            let collectionPath = resolveCollectionPath(config: config)
            let fullPath = resolveFullPath(source: source, config: config)
            FileWatcherService.shared.registerSelfModification(fullPath)
            _ = try runMtn(args: ["update", source.filePath, "--status", "open"], collectionPath: collectionPath)
            return
        }

        // Fallback to file-based
        let fileURL = URL(fileURLWithPath: resolveFullPath(source: source, config: config))
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ObsidianError.fileNotFound(fileURL.path)
        }

        FileWatcherService.shared.registerSelfModification(fileURL.path)
        try backupService.backupFile(at: fileURL)

        var content = try String(contentsOf: fileURL, encoding: .utf8)
        content = updateFrontmatterField(in: content, field: "status", value: "open")
        content = removeFrontmatterField(in: content, field: "completedDate")

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }

        if integrationMode == .cli, effectiveMtnPath != nil {
            try updateTaskMetadataViaCli(task: task, changes: changes, config: config)
            return
        }

        // Fallback to file-based
        let fileURL = URL(fileURLWithPath: resolveFullPath(source: source, config: config))
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ObsidianError.fileNotFound(fileURL.path)
        }

        FileWatcherService.shared.registerSelfModification(fileURL.path)
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
                content = updateFrontmatterField(in: content, field: "scheduled", value: dateFormatter.string(from: date))
            } else {
                content = removeFrontmatterField(in: content, field: "scheduled")
            }
        }

        if let newPriority = changes.newPriority {
            let priorityStr: String
            switch newPriority {
            case .high: priorityStr = "high"
            case .medium: priorityStr = "normal"
            case .low: priorityStr = "low"
            case .none: priorityStr = "normal"
            }
            content = updateFrontmatterField(in: content, field: "priority", value: priorityStr)
        }

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func updateTaskMetadataViaCli(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {
        guard let source = task.obsidianSource else {
            throw ObsidianError.noSourceInformation
        }

        let collectionPath = resolveCollectionPath(config: config)
        let fullPath = resolveFullPath(source: source, config: config)
        FileWatcherService.shared.registerSelfModification(fullPath)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        var args = ["update", source.filePath]

        if let dueDateChange = changes.newDueDate {
            if let date = dueDateChange {
                args += ["--due", dateFormatter.string(from: date)]
            }
        }

        if let startDateChange = changes.newStartDate {
            if let date = startDateChange {
                args += ["--scheduled", dateFormatter.string(from: date)]
            }
        }

        if let newPriority = changes.newPriority {
            let priorityStr: String
            switch newPriority {
            case .high: priorityStr = "high"
            case .medium: priorityStr = "normal"
            case .low: priorityStr = "low"
            case .none: priorityStr = "normal"
            }
            args += ["--priority", priorityStr]
        }

        if args.count > 2 {
            _ = try runMtn(args: args, collectionPath: collectionPath)
        }
    }

    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        if integrationMode == .cli, effectiveMtnPath != nil {
            return try appendNewTaskViaCli(task, config: config)
        }

        // Fallback to file-based creation
        return try appendNewTaskViaFiles(task, config: config)
    }

    private func appendNewTaskViaCli(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        let collectionPath = resolveCollectionPath(config: config)

        // Build natural language input for mtn create
        var createText = task.title

        if let dueDate = task.dueDate {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            createText += " due:\(dateFormatter.string(from: dueDate))"
        }

        if task.priority == .high {
            createText += " high priority"
        } else if task.priority == .low {
            createText += " low priority"
        }

        for tag in task.tags {
            let tagName = tag.hasPrefix("#") ? tag : "#\(tag)"
            createText += " \(tagName)"
        }

        let output = try runMtn(args: ["create", createText], collectionPath: collectionPath)
        debugLog("[TaskNotes] Created task via CLI: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Try to find the created file by listing recent tasks
        let sanitizedTitle = task.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .prefix(50)
        let relativePath = "/tasks/\(sanitizedTitle).md"

        return SyncTask.ObsidianSource(
            filePath: relativePath,
            lineNumber: 1,
            originalLine: "# \(task.title)"
        )
    }

    private func appendNewTaskViaFiles(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        let tasksDir = config.taskNotesFolder.isEmpty ? "tasks" : config.taskNotesFolder
        let dirURL = URL(fileURLWithPath: config.vaultPath).appendingPathComponent(tasksDir)

        if !fileManager.fileExists(atPath: dirURL.path) {
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        // Generate filename from title (mdbase-style slugification)
        let sanitizedTitle = task.title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .prefix(50)
        let fileName = "\(sanitizedTitle).md"
        var fileURL = dirURL.appendingPathComponent(String(fileName))

        // If file already exists, add a UUID suffix
        if fileManager.fileExists(atPath: fileURL.path) {
            let uniqueName = "\(sanitizedTitle)-\(UUID().uuidString.prefix(8)).md"
            fileURL = dirURL.appendingPathComponent(String(uniqueName))
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Build YAML frontmatter (mdbase-tasknotes format)
        var frontmatter = "---\n"
        frontmatter += "title: \(task.title)\n"
        frontmatter += "status: \(task.isCompleted ? "done" : "open")\n"

        let priorityStr: String
        switch task.priority {
        case .high: priorityStr = "high"
        case .medium: priorityStr = "normal"
        case .low: priorityStr = "low"
        case .none: priorityStr = "normal"
        }
        frontmatter += "priority: \(priorityStr)\n"

        if let dueDate = task.dueDate {
            frontmatter += "due: \(dateFormatter.string(from: dueDate))\n"
        }

        if let startDate = task.startDate {
            frontmatter += "scheduled: \(dateFormatter.string(from: startDate))\n"
        }

        if !task.tags.isEmpty {
            let tagNames = task.tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            frontmatter += "tags:\n"
            for tag in tagNames {
                frontmatter += "  - \(tag)\n"
            }
        }

        frontmatter += "dateCreated: \(dateFormatter.string(from: Date()))\n"

        if task.isCompleted, let completedDate = task.completedDate {
            frontmatter += "completedDate: \(dateFormatter.string(from: completedDate))\n"
        }

        frontmatter += "---\n"

        // Build content
        var content = frontmatter
        content += "\n"
        if let notes = task.notes, !notes.isEmpty {
            content += "\(notes)\n"
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
        let fileURL = URL(fileURLWithPath: resolveFullPath(source: source, config: config))
        guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return true
        }
        return modDate > timestamp
    }

    // MARK: - Path Helpers

    private func resolveCollectionPath(config: SyncConfiguration) -> String {
        if config.taskNotesFolder.isEmpty {
            return config.vaultPath
        }
        return config.vaultPath + "/" + config.taskNotesFolder
    }

    private func resolveFullPath(source: SyncTask.ObsidianSource, config: SyncConfiguration) -> String {
        return config.vaultPath + source.filePath
    }

    // MARK: - File-Based Scanning

    private func scanTasksFromFiles(config: SyncConfiguration) throws -> [SyncTask] {
        let tasksDir = config.taskNotesFolder.isEmpty ? "tasks" : config.taskNotesFolder
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

        var status = "open"
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
                    case "title":
                        if !value.isEmpty { title = value }
                    case "status":
                        status = value
                    case "priority":
                        switch value.lowercased() {
                        case "high", "urgent": priority = .high
                        case "medium", "normal": priority = .medium
                        case "low": priority = .low
                        default: priority = .none
                        }
                    case "due":
                        dueDate = dateFormatter.date(from: value)
                    case "scheduled", "start":
                        startDate = dateFormatter.date(from: value)
                    case "completeddate", "completed":
                        completedDate = isoFormatter.date(from: value) ?? dateFormatter.date(from: value)
                    case "tags":
                        // Parse YAML inline array: [tag1, tag2]
                        let cleaned = value
                            .replacingOccurrences(of: "[", with: "")
                            .replacingOccurrences(of: "]", with: "")
                        if !cleaned.isEmpty {
                            tags = cleaned.components(separatedBy: ",").map { "#\($0.trimmingCharacters(in: .whitespaces))" }
                        }
                    default:
                        break
                    }
                } else if trimmed.hasPrefix("- ") && !tags.isEmpty {
                    // YAML multi-line array item (under tags:)
                    // This is a simplification — only works right after tags:
                    let tagValue = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !tagValue.isEmpty {
                        tags.append("#\(tagValue)")
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

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
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

        let decoder = JSONDecoder()
        let apiTasks = try decoder.decode([TaskNotesApiTask].self, from: data)
        return apiTasks.map { $0.toSyncTask() }
    }

    // MARK: - Frontmatter Helpers

    func updateFrontmatterField(in content: String, field: String, value: String) -> String {
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

    func removeFrontmatterField(in content: String, field: String) -> String {
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

// MARK: - CLI JSON Response Model

private struct MtnCliTask: Codable {
    let title: String?
    let status: String?
    let priority: String?
    let due: String?
    let scheduled: String?
    let completedDate: String?
    let tags: [String]?
    let contexts: [String]?
    let path: String?
    let dateCreated: String?
    let dateModified: String?
    let timeEstimate: Int?

    func toSyncTask() -> SyncTask {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let taskTitle = title ?? "Untitled"
        let isCompleted = status == "done" || status == "completed"

        let taskPriority: SyncTask.Priority
        switch priority?.lowercased() {
        case "high", "urgent": taskPriority = .high
        case "medium", "normal": taskPriority = .medium
        case "low": taskPriority = .low
        default: taskPriority = .none
        }

        let taskTags = (tags ?? []).map { "#\($0)" }
        let relativePath = path ?? "/tasks/\(taskTitle.lowercased().replacingOccurrences(of: " ", with: "-")).md"

        return SyncTask(
            title: taskTitle,
            isCompleted: isCompleted,
            priority: taskPriority,
            dueDate: due.flatMap { dateFormatter.date(from: $0) },
            startDate: scheduled.flatMap { dateFormatter.date(from: $0) },
            completedDate: completedDate.flatMap { dateFormatter.date(from: $0) },
            tags: taskTags,
            targetList: taskTags.first.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 },
            obsidianSource: SyncTask.ObsidianSource(
                filePath: relativePath,
                lineNumber: 1,
                originalLine: "# \(taskTitle)"
            ),
            lastModified: dateModified.flatMap { dateFormatter.date(from: $0) } ?? Date()
        )
    }
}

// MARK: - API Response Models

private struct TaskNotesApiTask: Codable {
    let id: String?
    let title: String
    let status: String?
    let priority: String?
    let due: String?
    let scheduled: String?
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
        case "high", "urgent": taskPriority = .high
        case "medium", "normal": taskPriority = .medium
        case "low": taskPriority = .low
        default: taskPriority = .none
        }

        let taskTags = (tags ?? []).map { "#\($0)" }

        return SyncTask(
            title: title,
            isCompleted: isCompleted,
            priority: taskPriority,
            dueDate: due.flatMap { dateFormatter.date(from: $0) },
            startDate: (scheduled ?? start).flatMap { dateFormatter.date(from: $0) },
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
    case mtnNotFound
    case cliError(String)

    var errorDescription: String? {
        switch self {
        case .noFrontmatter(let file):
            return "TaskNotes file has no YAML frontmatter: \(file)"
        case .invalidApiUrl:
            return "Invalid TaskNotes API URL"
        case .apiError(let message):
            return "TaskNotes API error: \(message)"
        case .mtnNotFound:
            return "mdbase-tasknotes CLI (mtn) not found. Install with: npm install -g mdbase-tasknotes — then go to Settings > Advanced and click 'Browse...' to select the mtn binary (run 'which mtn' in Terminal to find it)"
        case .cliError(let message):
            return "TaskNotes CLI error: \(message)"
        }
    }
}
