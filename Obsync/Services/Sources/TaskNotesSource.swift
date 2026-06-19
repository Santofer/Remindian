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

    /// Produce a filesystem-safe, human-readable slug from a task title.
    ///
    /// Unicode-aware: keeps letters, marks and numbers from ANY script, so
    /// "Nu försöker vi med åäö" stays "nu-försöker-vi-med-åäö" and "买牛奶"
    /// stays "买牛奶" — diacritics and non-Latin scripts are preserved, not
    /// stripped (#79, replacing the old ASCII-folding behaviour from #73). Only
    /// characters that are unsafe or noisy in a filename are removed (path
    /// separators, punctuation, emoji); whitespace collapses to single hyphens
    /// for tidy, link-friendly names. Falls back to a stable token when the
    /// result would be empty so we never emit a bare ".md" filename.
    ///
    /// The displayed task title is always preserved separately in the file's
    /// YAML frontmatter (`title:`); this only affects the on-disk filename.
    static func slugify(_ title: String, maxLength: Int = 50) -> String {
        let slug = title
            .lowercased()
            // Keep Unicode letters (\p{L}), combining marks (\p{M}), numbers
            // (\p{N}), whitespace, underscores and hyphens; drop the rest.
            .replacingOccurrences(of: "[^\\p{L}\\p{M}\\p{N}\\s_-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
            .prefix(maxLength)
        let result = String(slug)
        return result.isEmpty ? "task-\(UUID().uuidString.prefix(8))" : result
    }

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

    /// Custom status mapping (#10)
    var completedStatuses: [String] = ["done", "completed", "cancelled"]
    var openStatus: String = "open"
    var doneStatus: String = "done"

    /// Configurable field name mapping (#19)
    var fieldMapping: TaskNotesFieldMapping = TaskNotesFieldMapping()

    /// Which field determines Reminders list (#20): "tags", "project", "context", or custom
    var listField: String = "tags"

    /// A tag automatically added to every note created from a reminder (#78).
    /// Empty = none. Lets users who sync Reminders → TaskNotes stamp a fixed tag
    /// (e.g. "task") even though Apple Reminders don't carry tags into EventKit.
    var defaultTag: String = ""

    /// Check if a status value represents a completed task.
    func isStatusCompleted(_ status: String) -> Bool {
        return completedStatuses.contains { $0.lowercased() == status.lowercased() }
    }

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
    /// Uses /bin/sh -c to execute the command with an augmented PATH that includes
    /// common bin directories (homebrew, npm-global, /usr/local/bin).
    /// Note: we intentionally avoid -l (login shell) because macOS sandbox blocks
    /// sourcing /etc/profile, causing "Operation not permitted" errors (#45).
    private func runMtn(args: [String], collectionPath: String) throws -> String {
        // Build the full command string for shell execution
        let mtnBinary: String

        if let directPath = effectiveMtnPath {
            // Pre-flight: check if the binary exists and is executable
            if !FileManager.default.isExecutableFile(atPath: directPath) {
                if FileManager.default.fileExists(atPath: directPath) {
                    throw TaskNotesError.cliError("mtn found at \(directPath) but is not executable. Fix with: chmod +x \(directPath)")
                } else {
                    throw TaskNotesError.cliError("mtn not found at \(directPath). Install with: npm install -g mtn")
                }
            }
            mtnBinary = directPath
        } else {
            // Fall back to just "mtn" and rely on the shell's PATH
            mtnBinary = "mtn"
        }

        // Escape the collection path and args for shell
        let escapedPath = collectionPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedArgs = args.map { $0.replacingOccurrences(of: "'", with: "'\\''") }
        let fullCommand = "'\(mtnBinary)' -p '\(escapedPath)' " + escapedArgs.map { "'\($0)'" }.joined(separator: " ")

        debugLog("[TaskNotes] Running: /bin/sh -c \"\(fullCommand)\"")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", fullCommand]

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
            let hint: String
            switch process.terminationStatus {
            case 126:
                hint = "mtn is not executable. Try: chmod +x \(mtnBinary)"
            case 127:
                hint = "mtn not found. Install with: npm install -g mtn"
            default:
                hint = errorOutput
            }
            throw TaskNotesError.cliError("mtn exited with code \(process.terminationStatus): \(hint)")
        }

        return output
    }

    // MARK: - Task Scanning

    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] {
        switch integrationMode {
        case .cli:
            do {
                return try scanTasksViaCli(config: config)
            } catch let error as TaskNotesError {
                // Auto-fallback: if CLI fails with sandbox permission error (exit 126/127),
                // switch to file-based mode which doesn't need external binaries
                if case .cliError(let msg) = error, (msg.contains("code 126") || msg.contains("code 127") || msg.contains("not executable") || msg.contains("not found")) {
                    debugLog("[TaskNotes] CLI not accessible in sandbox — auto-switching to direct file mode")
                    integrationMode = .fileBased
                    return try scanTasksFromFiles(config: config)
                }
                throw error
            }
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
            return "tasknotes|\(components.joined(separator: "|").data(using: .utf8)?.base64EncodedString() ?? "")"
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
        let tasks = cliTasks.map { $0.toSyncTask(completedStatuses: self.completedStatuses, listField: self.listField) }

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

        content = updateFrontmatterField(in: content, field: fieldMapping.status, value: doneStatus)
        content = updateFrontmatterField(in: content, field: fieldMapping.completedDate, value: dateStr)

        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        auditLog.logFileModification(
            action: "taskNotesComplete",
            filePath: source.filePath,
            lineNumber: 0,
            beforeLine: "\(fieldMapping.status): \(openStatus)",
            afterLine: "\(fieldMapping.status): \(doneStatus)"
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
            _ = try runMtn(args: ["update", source.filePath, "--status", openStatus], collectionPath: collectionPath)
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
        content = updateFrontmatterField(in: content, field: fieldMapping.status, value: openStatus)
        content = removeFrontmatterField(in: content, field: fieldMapping.completedDate)

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
                content = updateFrontmatterField(in: content, field: fieldMapping.due, value: dateFormatter.string(from: date))
            } else {
                content = removeFrontmatterField(in: content, field: fieldMapping.due)
            }
        }

        if let startDateChange = changes.newStartDate {
            if let date = startDateChange {
                content = updateFrontmatterField(in: content, field: fieldMapping.scheduled, value: dateFormatter.string(from: date))
            } else {
                content = removeFrontmatterField(in: content, field: fieldMapping.scheduled)
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
            content = updateFrontmatterField(in: content, field: fieldMapping.priority, value: priorityStr)
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
        // Stamp the configured default tag if it isn't already present. (#78)
        if !defaultTag.isEmpty {
            let dt = defaultTag.hasPrefix("#") ? defaultTag : "#\(defaultTag)"
            let existing = task.tags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }
            if !existing.contains(dt) { createText += " \(dt)" }
        }

        let output = try runMtn(args: ["create", createText], collectionPath: collectionPath)
        debugLog("[TaskNotes] Created task via CLI: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Try to find the created file by listing recent tasks
        let sanitizedTitle = Self.slugify(task.title)
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

        // Generate filename from title (Unicode-aware slugification, #73)
        let sanitizedTitle = Self.slugify(task.title)
        let fileName = "\(sanitizedTitle).md"
        var fileURL = dirURL.appendingPathComponent(fileName)

        // If file already exists, add a UUID suffix
        if fileManager.fileExists(atPath: fileURL.path) {
            let uniqueName = "\(sanitizedTitle)-\(UUID().uuidString.prefix(8)).md"
            fileURL = dirURL.appendingPathComponent(uniqueName)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Build YAML frontmatter using mapped field names (#19)
        let fm = fieldMapping
        var frontmatter = "---\n"
        frontmatter += "\(fm.title): \(task.title)\n"
        frontmatter += "\(fm.status): \(task.isCompleted ? doneStatus : openStatus)\n"

        let priorityStr: String
        switch task.priority {
        case .high: priorityStr = "high"
        case .medium: priorityStr = "normal"
        case .low: priorityStr = "low"
        case .none: priorityStr = "normal"
        }
        frontmatter += "\(fm.priority): \(priorityStr)\n"

        if let dueDate = task.dueDate {
            frontmatter += "\(fm.due): \(dateFormatter.string(from: dueDate))\n"
        }

        if let startDate = task.startDate {
            frontmatter += "\(fm.scheduled): \(dateFormatter.string(from: startDate))\n"
        }

        var tagNames = task.tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        // Stamp the configured default tag if it isn't already present. (#78)
        let dt = defaultTag.hasPrefix("#") ? String(defaultTag.dropFirst()) : defaultTag
        if !dt.isEmpty && !tagNames.contains(dt) { tagNames.append(dt) }
        if !tagNames.isEmpty {
            frontmatter += "\(fm.tags):\n"
            for tag in tagNames {
                frontmatter += "  - \(tag)\n"
            }
        }

        // Write list field value when using project/context (#20)
        if let targetList = task.targetList, !targetList.isEmpty {
            let lf = listField.lowercased()
            if lf == "project" {
                frontmatter += "\(fm.project): \(targetList)\n"
            } else if lf == "context" {
                frontmatter += "\(fm.context): \(targetList)\n"
            } else if lf != "tags" {
                frontmatter += "\(listField): \(targetList)\n"
            }
        }

        frontmatter += "dateCreated: \(dateFormatter.string(from: Date()))\n"

        if task.isCompleted, let completedDate = task.completedDate {
            frontmatter += "\(fm.completedDate): \(dateFormatter.string(from: completedDate))\n"
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

        // Recurse into subdirectories so users can organize TaskNotes by project (#48)
        guard let enumerator = fileManager.enumerator(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            debugLog("[TaskNotes] Cannot enumerate: \(dirURL.path)")
            return []
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "md" else { continue }
            if let task = try? parseTaskNotesFile(fileURL, vaultPath: config.vaultPath) {
                tasks.append(task)
            }
        }

        debugLog("[TaskNotes] Found \(tasks.count) tasks in \(tasksDir)")
        return tasks
    }

    /// Strip wikilink brackets from a value (e.g., "[[My Project]]" → "My Project").
    private func stripWikilinks(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "[[", with: "")
        result = result.replacingOccurrences(of: "]]", with: "")
        return result.trimmingCharacters(in: .whitespaces)
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

        var status = openStatus
        var priority: SyncTask.Priority = .none
        var dueDate: Date?
        var startDate: Date?
        var completedDate: Date?
        var tags: [String] = []
        var title = fileURL.deletingPathExtension().lastPathComponent
        var projectValue: String?
        var contextValue: String?
        var customFieldValues: [String: String] = [:]  // For custom list field lookup

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let fm = fieldMapping
        let fieldLookup = fm.fieldLookup  // compute once; was rebuilt for every frontmatter line
        var inFrontmatter = false
        var frontmatterEnded = false
        var lastArrayKey: String?  // Track which key a YAML array item belongs to
        var bodyLines: [String] = []  // Content below frontmatter (notes body)
        var foundHeading = false

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
                    let key = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    var value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    // Strip YAML quotes if present (#28)
                    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                        value = String(value.dropFirst().dropLast())
                    }
                    let keyLower = key.lowercased()

                    // Store all field values for custom list field lookup (#20)
                    if !value.isEmpty {
                        customFieldValues[keyLower] = value
                    }

                    // Use field mapping to identify which property this field represents (#19)
                    let property = fm.fieldLookup[keyLower]

                    switch property {
                    case "title":
                        if !value.isEmpty { title = value }
                        lastArrayKey = nil
                    case "status":
                        status = value
                        lastArrayKey = nil
                    case "priority":
                        switch value.lowercased() {
                        case "high", "urgent": priority = .high
                        case "medium", "normal": priority = .medium
                        case "low": priority = .low
                        default: priority = .none
                        }
                        lastArrayKey = nil
                    case "due":
                        dueDate = dateFormatter.date(from: value)
                        lastArrayKey = nil
                    case "scheduled":
                        startDate = dateFormatter.date(from: value)
                        lastArrayKey = nil
                    case "completedDate":
                        completedDate = isoFormatter.date(from: value) ?? dateFormatter.date(from: value)
                        lastArrayKey = nil
                    case "tags":
                        // Parse YAML inline array: [tag1, tag2]
                        let cleaned = value
                            .replacingOccurrences(of: "[", with: "")
                            .replacingOccurrences(of: "]", with: "")
                        if !cleaned.isEmpty {
                            tags = cleaned.components(separatedBy: ",").map { "#\($0.trimmingCharacters(in: .whitespaces))" }
                        }
                        lastArrayKey = "tags"
                    case "project":
                        projectValue = stripWikilinks(value)
                        lastArrayKey = nil
                    case "context":
                        contextValue = stripWikilinks(value)
                        lastArrayKey = nil
                    default:
                        // Also check for legacy field names that aren't in the mapping
                        switch keyLower {
                        case "start":
                            startDate = dateFormatter.date(from: value)
                        case "completed":
                            completedDate = isoFormatter.date(from: value) ?? dateFormatter.date(from: value)
                        default:
                            break
                        }
                        lastArrayKey = nil
                    }
                } else if trimmed.hasPrefix("- ") && lastArrayKey == "tags" {
                    // YAML multi-line array item (under tags:)
                    let tagValue = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !tagValue.isEmpty {
                        tags.append("#\(tagValue)")
                    }
                } else {
                    lastArrayKey = nil
                }
            }

            // Parse title from first heading after frontmatter
            if frontmatterEnded && trimmed.hasPrefix("# ") && !foundHeading {
                title = String(trimmed.dropFirst(2))
                foundHeading = true
            } else if frontmatterEnded && foundHeading {
                // Collect body lines after the heading (task notes content)
                bodyLines.append(line)
            }
        }

        // Build notes from body content (trimmed)
        let notesBody = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        let isCompleted = isStatusCompleted(status)

        // Determine target list based on listField setting (#20)
        let targetList: String?
        switch listField.lowercased() {
        case "project":
            targetList = projectValue
        case "context":
            targetList = contextValue
        case "tags":
            targetList = tags.first.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        default:
            // Custom field name — look it up in parsed values
            if let customValue = customFieldValues[listField.lowercased()], !customValue.isEmpty {
                targetList = stripWikilinks(customValue)
            } else {
                targetList = tags.first.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            }
        }

        return SyncTask(
            title: title,
            isCompleted: isCompleted,
            priority: priority,
            dueDate: dueDate,
            startDate: startDate,
            completedDate: completedDate,
            tags: tags,
            targetList: targetList,
            notes: notesBody.isEmpty ? nil : notesBody,
            obsidianSource: SyncTask.ObsidianSource(
                filePath: relativePath,
                lineNumber: 1,
                originalLine: "# \(title)"
            ),
            lastModified: completedDate ?? Date()
        )
    }

    // MARK: - HTTP API

    private func responseSnippet(from data: Data) -> String {
        guard let body = String(data: data, encoding: .utf8) else { return "<non-UTF8 response>" }
        let compact = body.replacingOccurrences(of: "\n", with: " ")
        return String(compact.prefix(240))
    }

    /// Decode API tasks from various response formats:
    /// - Raw array: `[{...}, {...}]`
    /// - Envelope: `{ success: true, data: [...] }`
    /// - Collection: `{ success: true, data: { tasks: [...] } }` (also `items`, `results`)
    private func decodeApiTasks(from data: Data) throws -> [TaskNotesApiTask] {
        let decoder = JSONDecoder()

        // Try raw array first (most common)
        if let directArray = try? decoder.decode([TaskNotesApiTask].self, from: data) {
            return directArray
        }

        // Try { success, data: [...] } envelope
        if let envelope = try? decoder.decode(TaskNotesApiEnvelope<[TaskNotesApiTask]>.self, from: data) {
            if envelope.success == false {
                throw TaskNotesError.apiError(envelope.error ?? envelope.message ?? "API returned success=false")
            }
            if let tasks = envelope.data {
                return tasks
            }
        }

        // Try { success, data: { tasks/items/results: [...] } } envelope
        if let envelope = try? decoder.decode(TaskNotesApiEnvelope<TaskNotesApiTaskCollection>.self, from: data) {
            if envelope.success == false {
                throw TaskNotesError.apiError(envelope.error ?? envelope.message ?? "API returned success=false")
            }
            if let payload = envelope.data {
                if let tasks = payload.tasks { return tasks }
                if let tasks = payload.items { return tasks }
                if let tasks = payload.results { return tasks }
            }
        }

        throw TaskNotesError.apiError("Unexpected /api/tasks response format: \(responseSnippet(from: data))")
    }

    private func scanTasksViaApi() throws -> [SyncTask] {
        guard let url = URL(string: "\(apiBaseUrl)/api/tasks") else {
            throw TaskNotesError.invalidApiUrl
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var httpStatusCode: Int?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            responseError = error
            httpStatusCode = (response as? HTTPURLResponse)?.statusCode
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

        if let statusCode = httpStatusCode, !(200...299).contains(statusCode) {
            throw TaskNotesError.apiError("HTTP \(statusCode): \(responseSnippet(from: data))")
        }

        let apiTasks = try decodeApiTasks(from: data)
        return apiTasks.map { $0.toSyncTask(completedStatuses: self.completedStatuses, listField: self.listField) }
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
    let project: String?
    let path: String?
    let dateCreated: String?
    let dateModified: String?
    let timeEstimate: Int?

    func toSyncTask(completedStatuses: [String] = ["done", "completed", "cancelled"], listField: String = "tags") -> SyncTask {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let taskTitle = title ?? "Untitled"
        let isCompleted = completedStatuses.contains { $0.lowercased() == (status ?? "").lowercased() }

        let taskPriority: SyncTask.Priority
        switch priority?.lowercased() {
        case "high", "urgent": taskPriority = .high
        case "medium", "normal": taskPriority = .medium
        case "low": taskPriority = .low
        default: taskPriority = .none
        }

        let taskTags = (tags ?? []).map { "#\($0)" }
        // Prefer the path the mtn CLI reported; only synthesize one when it's
        // missing. Use the shared Unicode-aware slug so the fallback matches
        // the file-creation path and doesn't mangle accents. (#73)
        let relativePath = path ?? "/tasks/\(TaskNotesSource.slugify(taskTitle)).md"

        // Determine target list based on listField (#20)
        let targetList: String?
        switch listField.lowercased() {
        case "project":
            targetList = project?.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "").trimmingCharacters(in: .whitespaces)
        case "context":
            targetList = contexts?.first?.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "").trimmingCharacters(in: .whitespaces)
        default:
            targetList = taskTags.first.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        }

        return SyncTask(
            title: taskTitle,
            isCompleted: isCompleted,
            priority: taskPriority,
            dueDate: due.flatMap { dateFormatter.date(from: $0) },
            startDate: scheduled.flatMap { dateFormatter.date(from: $0) },
            completedDate: completedDate.flatMap { dateFormatter.date(from: $0) },
            tags: taskTags,
            targetList: targetList,
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
    let project: String?
    let context: String?
    let notes: String?
    let filePath: String?

    func toSyncTask(completedStatuses: [String] = ["done", "completed", "cancelled"], listField: String = "tags") -> SyncTask {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let isCompleted = completedStatuses.contains { $0.lowercased() == (status ?? "").lowercased() }
        let taskPriority: SyncTask.Priority
        switch priority?.lowercased() {
        case "high", "urgent": taskPriority = .high
        case "medium", "normal": taskPriority = .medium
        case "low": taskPriority = .low
        default: taskPriority = .none
        }

        let taskTags = (tags ?? []).map { "#\($0)" }

        // Determine target list based on listField (#20)
        let targetList: String?
        switch listField.lowercased() {
        case "project":
            targetList = project?.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "").trimmingCharacters(in: .whitespaces)
        case "context":
            targetList = context?.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "").trimmingCharacters(in: .whitespaces)
        default:
            targetList = taskTags.first.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        }

        return SyncTask(
            title: title,
            isCompleted: isCompleted,
            priority: taskPriority,
            dueDate: due.flatMap { dateFormatter.date(from: $0) },
            startDate: (scheduled ?? start).flatMap { dateFormatter.date(from: $0) },
            completedDate: completed.flatMap { dateFormatter.date(from: $0) },
            tags: taskTags,
            targetList: targetList,
            notes: notes,
            obsidianSource: filePath.map { SyncTask.ObsidianSource(filePath: $0, lineNumber: 1, originalLine: "# \(title)") },
            remindersId: id
        )
    }
}

// MARK: - API Response Envelope Models (supports wrapped responses)

private struct TaskNotesApiEnvelope<T: Decodable>: Decodable {
    let success: Bool?
    let data: T?
    let error: String?
    let message: String?
}

private struct TaskNotesApiTaskCollection: Decodable {
    let tasks: [TaskNotesApiTask]?
    let items: [TaskNotesApiTask]?
    let results: [TaskNotesApiTask]?
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
