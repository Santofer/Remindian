import Foundation

/// Service for reading Obsidian vault files and performing safe surgical edits.
/// IMPORTANT: This service NEVER reconstructs task lines. All writes are surgical
/// modifications to the original line content, preserving all metadata verbatim.
class ObsidianService {
    private let fileManager = FileManager.default
    private let backupService = FileBackupService.shared
    private let auditLog = AuditLog.shared

    // MARK: - Reading Tasks

    /// Scan vault for all tasks matching the Obsidian Tasks format
    func scanVault(
        at path: String,
        excludedFolders: [String],
        includedFolders: [String] = [],
        openMarkers: Set<Character> = SyncTask.defaultOpenMarkers,
        completedMarkers: Set<Character> = SyncTask.defaultCompletedMarkers,
        ignoredMarkers: Set<Character> = []
    ) throws -> [SyncTask] {
        let vaultURL = URL(fileURLWithPath: path)
        guard fileManager.fileExists(atPath: path) else {
            debugLog("[ObsidianService] Vault path does not exist: \(path)")
            throw ObsidianError.vaultNotFound(path)
        }
        debugLog("[ObsidianService] Vault exists at: \(path)")

        // Check if we can actually read the directory
        let isReadable = fileManager.isReadableFile(atPath: path)
        debugLog("[ObsidianService] Directory readable: \(isReadable)")

        var tasks: [SyncTask] = []
        let markdownFiles = try findMarkdownFiles(in: vaultURL, excluding: excludedFolders, including: includedFolders)
        debugLog("[ObsidianService] Found \(markdownFiles.count) markdown files")

        for fileURL in markdownFiles {
            do {
                let fileTasks = try parseTasksFromFile(
                    fileURL,
                    vaultPath: path,
                    openMarkers: openMarkers,
                    completedMarkers: completedMarkers,
                    ignoredMarkers: ignoredMarkers
                )
                tasks.append(contentsOf: fileTasks)
            } catch {
                // Skip files that can't be read (e.g., deleted between scan and read,
                // permission issues, or broken symlinks)
                debugLog("[ObsidianService] Skipping unreadable file: \(fileURL.lastPathComponent) — \(error.localizedDescription)")
            }
        }

        debugLog("[ObsidianService] Total tasks found: \(tasks.count)")
        return tasks
    }

    /// Parse tasks from a single markdown file.
    ///
    /// Extracts frontmatter `client` property (e.g., `client: "[[Bodycare Travel]]"`) and
    /// passes it to each task as clientName.
    ///
    /// After per-line parsing, runs a **parent-tag inheritance pass**: an
    /// indented child task without its own `targetList` inherits from the
    /// nearest preceding less-indented parent. Without this, subtasks would
    /// fall through to the default list because they have no tag of their
    /// own — addressing the user pain reported in #66. Real parent/child
    /// nesting at the destination (`EKReminder.parentItem`, TickTick
    /// `parentId`, etc.) is a future phase; this is a behavioral compromise
    /// that puts indented subtasks in the *same list* as their parent.
    func parseTasksFromFile(
        _ fileURL: URL,
        vaultPath: String,
        openMarkers: Set<Character> = SyncTask.defaultOpenMarkers,
        completedMarkers: Set<Character> = SyncTask.defaultCompletedMarkers,
        ignoredMarkers: Set<Character> = []
    ) throws -> [SyncTask] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let relativePath = fileURL.path.replacingOccurrences(of: vaultPath, with: "")

        // Extract client name from YAML frontmatter
        let clientName = extractFrontmatterClient(from: content)

        // Pair each parsed task with the indent level of its source line so we
        // can run parent-inheritance below. We can't store indent on SyncTask
        // itself without bloating the model — local-only computation is fine.
        var taggedTasks: [(indent: Int, task: SyncTask)] = []

        for (index, line) in lines.enumerated() {
            if var task = SyncTask.fromObsidianLine(
                line,
                filePath: relativePath,
                lineNumber: index + 1,
                openMarkers: openMarkers,
                completedMarkers: completedMarkers,
                ignoredMarkers: ignoredMarkers
            ) {
                // Attach client name from frontmatter for work tasks
                if clientName != nil {
                    task.clientName = clientName
                }
                let indent = leadingWhitespaceCount(line)
                taggedTasks.append((indent, task))
            }
        }

        // Parent-tag inheritance pass (#66 Phase 1). For each task that has
        // no explicit `targetList`, walk back through the in-order list to
        // find the nearest preceding task with a strictly smaller indent
        // level — that's the structural parent. Inherit its `targetList` and
        // also append the parent's first tag so the child's writeback to
        // disk doesn't lose the routing hint.
        //
        // Stack-based approach: maintain a stack of (indent, task) ancestors.
        // For each new task, pop entries with indent >= current. The top of
        // the stack (if any) is the parent. Constant amortized cost per task.
        var ancestorStack: [(indent: Int, task: SyncTask)] = []
        var tasks: [SyncTask] = []
        tasks.reserveCapacity(taggedTasks.count)

        for (indent, originalTask) in taggedTasks {
            // Pop siblings/deeper-or-equal entries off the stack.
            while let top = ancestorStack.last, top.indent >= indent {
                ancestorStack.removeLast()
            }

            var task = originalTask
            if task.targetList == nil, let parent = ancestorStack.last?.task {
                task.targetList = parent.targetList
                // Also inherit the parent's first tag so toObsidianLine
                // preserves the routing hint on writeback. Avoid duplicate
                // tags if the child somehow already had it.
                if let parentTag = parent.tags.first,
                   !task.tags.contains(parentTag) {
                    task.tags.append(parentTag)
                }
            }

            ancestorStack.append((indent, task))
            tasks.append(task)
        }

        return tasks
    }

    /// Count leading whitespace characters (tabs and spaces both count as 1
    /// each — sufficient for relative depth comparison within a single file).
    private func leadingWhitespaceCount(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " || ch == "\t" {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    /// Extract the `client` property from YAML frontmatter.
    /// Handles formats like: `client: "[[Bodycare Travel]]"`, `client: Somfy`, `client: "[[Clay]]"`
    private func extractFrontmatterClient(from content: String) -> String? {
        let lines = content.components(separatedBy: "\n")

        // Check for YAML frontmatter (starts with ---)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        // Find the closing ---
        for i in 1..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line == "---" {
                break // End of frontmatter
            }

            // Look for client: property
            if line.lowercased().hasPrefix("client:") {
                var value = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)

                // Remove surrounding quotes
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }

                // Remove [[ ]] wikilink syntax
                value = value.replacingOccurrences(of: "[[", with: "")
                value = value.replacingOccurrences(of: "]]", with: "")

                return value.isEmpty ? nil : value
            }
        }

        return nil
    }

    // MARK: - Inbox Append (New Task Writeback)

    /// Append a new task to the inbox file in Obsidian Tasks format.
    /// This is a SAFE append-only operation — existing content is never modified.
    /// Creates the file if it doesn't exist.
    func appendTaskToInbox(
        task: SyncTask,
        inboxRelativePath: String,
        vaultPath: String
    ) throws -> (filePath: String, lineNumber: Int, lineContent: String) {
        let relativePath = inboxRelativePath.hasPrefix("/") ? inboxRelativePath : "/" + inboxRelativePath
        let fileURL = URL(fileURLWithPath: vaultPath + relativePath)

        // Create parent directories if needed
        let parentDir = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        // Build the task line in Obsidian Tasks format
        var parts: [String] = []
        parts.append(task.isCompleted ? "- [x]" : "- [ ]")
        parts.append(task.title)

        if task.priority != .none {
            parts.append(task.priority.obsidianEmoji)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        if let startDate = task.startDate {
            parts.append("🛫 \(formatter.string(from: startDate))")
        }

        if let dueDate = task.dueDate {
            parts.append("📅 \(formatter.string(from: dueDate))")
        }

        if task.isCompleted, let completedDate = task.completedDate {
            parts.append("✅ \(formatter.string(from: completedDate))")
        }

        // Add list/tag if available
        if let targetList = task.targetList, !targetList.isEmpty {
            let tag = "#\(targetList)"
            if !parts.contains(tag) {
                parts.append(tag)
            }
        }

        let taskLine = parts.joined(separator: " ")

        // Read existing content or start fresh
        var content: String
        if fileManager.fileExists(atPath: fileURL.path) {
            try backupService.backupFile(at: fileURL)
            content = try String(contentsOf: fileURL, encoding: .utf8)
        } else {
            content = ""
        }

        // Ensure content ends with a newline before appending
        if !content.isEmpty && !content.hasSuffix("\n") {
            content += "\n"
        }

        content += taskLine + "\n"

        // Register self-modification BEFORE the write, so FileWatcher ignores
        // the FSEvents notification we're about to generate. Without this, every
        // append to /Inbox.md triggers the watcher's debounced sync callback,
        // which runs another sync, which appends again — creating a runaway
        // loop that ate one user's Inbox.md (regression: 2026-04-30). All other
        // file-mutating methods in this service register before writing; the
        // omission here was the bug.
        FileWatcherService.shared.registerSelfModification(fileURL.path)

        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Calculate the line number of the appended task
        let lines = content.components(separatedBy: "\n")
        let lineNumber = lines.count - 1 // -1 because trailing newline creates empty last element

        auditLog.logFileModification(
            action: "appendToInbox",
            filePath: relativePath,
            lineNumber: lineNumber,
            beforeLine: "",
            afterLine: taskLine
        )

        return (filePath: relativePath, lineNumber: lineNumber, lineContent: taskLine)
    }

    // MARK: - Safe Surgical Edits

    /// Surgically mark a task as complete in its Obsidian source file.
    /// This method NEVER reconstructs the line — it modifies the original in place,
    /// preserving all metadata (recurrence, tags, dates, etc.) verbatim.
    /// Mark a task as complete and handle recurrence.
    /// Returns the number of lines inserted (0 or 1) so callers can track line offsets.
    @discardableResult
    func markTaskComplete(
        filePath: String,
        lineNumber: Int,
        originalLine: String,
        completionDate: Date,
        vaultPath: String
    ) throws -> Int {
        let fileURL = URL(fileURLWithPath: vaultPath + filePath)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ObsidianError.fileNotFound(fileURL.path)
        }

        // Register self-modification so FileWatcher ignores our changes
        FileWatcherService.shared.registerSelfModification(fileURL.path)

        // Backup before any modification
        try backupService.backupFile(at: fileURL)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")

        guard lineNumber > 0 && lineNumber <= lines.count else {
            throw ObsidianError.lineNumberOutOfRange(lineNumber, lines.count)
        }

        let currentLine = lines[lineNumber - 1]

        // Safety check: verify the line still matches what we expect
        guard currentLine.trimmingCharacters(in: .whitespaces) ==
              originalLine.trimmingCharacters(in: .whitespaces) else {
            throw ObsidianError.lineContentMismatch(
                expected: originalLine.trimmingCharacters(in: .whitespaces),
                found: currentLine.trimmingCharacters(in: .whitespaces)
            )
        }

        // Safety: skip if task is already completed (prevents double-writes).
        //
        // We look at the actual checkbox character — anything in the canonical
        // completed-marker set (`x`/`X`) means done. Non-standard "open"
        // markers like `/` (in progress), `?` (waiting), `<` (ready), or `-`
        // (cancelled, sometimes used as completed) need to be re-checkable as
        // complete; the old `contains("- [ ]")` check was too narrow. (#63)
        guard let currentCheckbox = SyncTask.extractCheckbox(from: currentLine.trimmingCharacters(in: .whitespaces)) else {
            debugLog("[ObsidianService] Line is not a task, skipping: \(currentLine.prefix(80))")
            return 0
        }
        if SyncTask.defaultCompletedMarkers.contains(currentCheckbox.marker) {
            debugLog("[ObsidianService] Task already completed (marker=[\(currentCheckbox.marker)]), skipping: \(currentLine.prefix(80))")
            return 0
        }

        var newLine = currentLine

        // Surgical edit: replace the existing marker character with `x`. Using
        // a regex anchored at the first checkbox so we don't accidentally
        // touch something later in the line that looks like a checkbox. (#63)
        if let checkboxRange = newLine.range(of: "- [\(currentCheckbox.marker)]") {
            newLine.replaceSubrange(checkboxRange, with: "- [x]")
        }

        // Append completion date if not already present
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: completionDate)
        let completionMarker = " \u{2705} \(dateStr)"

        if !newLine.contains("\u{2705}") {
            // Append before any trailing whitespace
            let trimmedEnd = newLine.replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression
            )
            newLine = trimmedEnd + completionMarker
        }

        lines[lineNumber - 1] = newLine

        // Handle recurrence: if the task has a 🔁 rule, insert a new uncompleted
        // task above the completed one (matching Obsidian Tasks plugin behavior).
        // The plugin doesn't detect external file edits, so we must do this ourselves.
        var linesInserted = 0
        if let recurrence = parseRecurrenceRule(from: currentLine) {
            debugLog("[ObsidianService] Recurrence detected: rule='\(recurrence.rule)', whenDone=\(recurrence.whenDone)")

            let datePattern = { (emoji: String, line: String) -> Date? in
                guard let regex = try? NSRegularExpression(pattern: "\(emoji)\u{FE0F}?\\s*(\\d{4}-\\d{2}-\\d{2})"),
                      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let dateRange = Range(match.range(at: 1), in: line) else { return nil }
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                return fmt.date(from: String(line[dateRange]))
            }

            let dueDate = datePattern("📅", currentLine)
            let scheduledDate = datePattern("⏳", currentLine)
            let startDate = datePattern("🛫", currentLine)
            let referenceDate = dueDate ?? scheduledDate ?? startDate

            if let refDate = referenceDate,
               let result = computeNextDate(
                   rule: recurrence.rule,
                   whenDone: recurrence.whenDone,
                   referenceDate: refDate,
                   completionDate: completionDate
               ) {
                let nextRefDate = result.referenceDate
                let calendar = Calendar.current

                var nextDue: Date? = nil
                var nextStart: Date? = nil
                var nextScheduled: Date? = nil

                if let d = dueDate {
                    if d == refDate { nextDue = nextRefDate }
                    else {
                        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: refDate), to: calendar.startOfDay(for: d)).day ?? 0
                        nextDue = calendar.date(byAdding: .day, value: offset, to: nextRefDate)
                    }
                }
                if let ruleStart = result.startDate {
                    nextStart = ruleStart
                } else if let d = startDate {
                    if d == refDate { nextStart = nextRefDate }
                    else {
                        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: refDate), to: calendar.startOfDay(for: d)).day ?? 0
                        nextStart = calendar.date(byAdding: .day, value: offset, to: nextRefDate)
                    }
                }
                if let d = scheduledDate {
                    if d == refDate { nextScheduled = nextRefDate }
                    else {
                        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: refDate), to: calendar.startOfDay(for: d)).day ?? 0
                        nextScheduled = calendar.date(byAdding: .day, value: offset, to: nextRefDate)
                    }
                }

                let recurrenceLine = buildRecurrenceLine(
                    originalLine: currentLine,
                    nextDueDate: nextDue,
                    nextStartDate: nextStart,
                    nextScheduledDate: nextScheduled
                )

                lines.insert(recurrenceLine, at: lineNumber - 1)
                linesInserted = 1

                debugLog("[ObsidianService] Inserted recurrence line: \(recurrenceLine)")
                auditLog.logFileModification(
                    action: "insertRecurrence",
                    filePath: filePath,
                    lineNumber: lineNumber,
                    beforeLine: "",
                    afterLine: recurrenceLine
                )
            }
        }

        let newContent = lines.joined(separator: "\n")
        try newContent.write(to: fileURL, atomically: true, encoding: .utf8)

        auditLog.logFileModification(
            action: "markTaskComplete",
            filePath: filePath,
            lineNumber: lineNumber,
            beforeLine: currentLine,
            afterLine: newLine
        )

        return linesInserted
    }

    /// Surgically mark a task as incomplete in its Obsidian source file.
    /// Reverses completion: changes "- [x]" to "- [ ]" and removes ✅ date.
    func markTaskIncomplete(
        filePath: String,
        lineNumber: Int,
        originalLine: String,
        vaultPath: String
    ) throws {
        let fileURL = URL(fileURLWithPath: vaultPath + filePath)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ObsidianError.fileNotFound(fileURL.path)
        }

        // Register self-modification so FileWatcher ignores our changes
        FileWatcherService.shared.registerSelfModification(fileURL.path)

        // Backup before any modification
        try backupService.backupFile(at: fileURL)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")

        guard lineNumber > 0 && lineNumber <= lines.count else {
            throw ObsidianError.lineNumberOutOfRange(lineNumber, lines.count)
        }

        let currentLine = lines[lineNumber - 1]

        // Safety check
        guard currentLine.trimmingCharacters(in: .whitespaces) ==
              originalLine.trimmingCharacters(in: .whitespaces) else {
            throw ObsidianError.lineContentMismatch(
                expected: originalLine.trimmingCharacters(in: .whitespaces),
                found: currentLine.trimmingCharacters(in: .whitespaces)
            )
        }

        var newLine = currentLine

        // Surgical edit: replace whatever the existing marker is with " "
        // (open). Same widening as markTaskComplete — covers `[x]`, `[X]`,
        // and any user-configured completed marker like `[-]`. (#63)
        if let checkbox = SyncTask.extractCheckbox(from: currentLine.trimmingCharacters(in: .whitespaces)),
           let range = newLine.range(of: "- [\(checkbox.marker)]") {
            newLine.replaceSubrange(range, with: "- [ ]")
        }

        // Remove completion date marker (✅ YYYY-MM-DD) — handle optional FE0F variation selector
        if let regex = try? NSRegularExpression(pattern: "\\s*\u{2705}\u{FE0F}?\\s*\\d{4}-\\d{2}-\\d{2}", options: []) {
            let nsRange = NSRange(newLine.startIndex..., in: newLine)
            newLine = regex.stringByReplacingMatches(in: newLine, options: [], range: nsRange, withTemplate: "")
        }

        lines[lineNumber - 1] = newLine
        let newContent = lines.joined(separator: "\n")
        try newContent.write(to: fileURL, atomically: true, encoding: .utf8)

        auditLog.logFileModification(
            action: "markTaskIncomplete",
            filePath: filePath,
            lineNumber: lineNumber,
            beforeLine: currentLine,
            afterLine: newLine
        )
    }

    // MARK: - Surgical Metadata Writeback

    /// Metadata changes to apply in a single atomic edit.
    struct MetadataChanges {
        var newDueDate: Date?? = nil    // nil = no change, .some(nil) = remove, .some(date) = set
        var newStartDate: Date?? = nil
        var newPriority: SyncTask.Priority? = nil  // nil = no change
        var newTags: [String]? = nil  // nil = no change, [] = remove all, ["#tag"] = set

        var hasChanges: Bool {
            return newDueDate != nil || newStartDate != nil || newPriority != nil || newTags != nil
        }
    }

    /// Surgically update multiple metadata fields in a task's Obsidian source line
    /// in a single atomic read-modify-write. This avoids the problem of stale originalLine
    /// when multiple fields change for the same task.
    func updateTaskMetadata(
        filePath: String,
        lineNumber: Int,
        originalLine: String,
        changes: MetadataChanges,
        vaultPath: String
    ) throws {
        guard changes.hasChanges else { return }

        let fileURL = URL(fileURLWithPath: vaultPath + filePath)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ObsidianError.fileNotFound(fileURL.path)
        }

        // Register self-modification so FileWatcher ignores our changes
        FileWatcherService.shared.registerSelfModification(fileURL.path)

        try backupService.backupFile(at: fileURL)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        // Use "\n" split to preserve original line endings (components(separatedBy: .newlines)
        // splits on \r, \n, and \r\n separately, which can corrupt files with CRLF endings)
        var lines = content.components(separatedBy: "\n")

        guard lineNumber > 0 && lineNumber <= lines.count else {
            throw ObsidianError.lineNumberOutOfRange(lineNumber, lines.count)
        }

        let currentLine = lines[lineNumber - 1]

        guard currentLine.trimmingCharacters(in: .whitespaces) ==
              originalLine.trimmingCharacters(in: .whitespaces) else {
            throw ObsidianError.lineContentMismatch(
                expected: originalLine.trimmingCharacters(in: .whitespaces),
                found: currentLine.trimmingCharacters(in: .whitespaces)
            )
        }

        var newLine = currentLine
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        // Apply due date change (📅)
        if let dueDateChange = changes.newDueDate {
            newLine = applyDateChange(to: newLine, emoji: "📅", emojiUnicode: "\u{1F4C5}", newDate: dueDateChange, formatter: formatter)
        }

        // Apply start date change (🛫)
        if let startDateChange = changes.newStartDate {
            newLine = applyDateChange(to: newLine, emoji: "🛫", emojiUnicode: "\u{1F6EB}", newDate: startDateChange, formatter: formatter)
        }

        // Apply priority change
        if let newPriority = changes.newPriority {
            newLine = applyPriorityChange(to: newLine, newPriority: newPriority)
        }

        // Apply tag changes (#17 — GoodTask tag writeback)
        if let newTags = changes.newTags {
            newLine = applyTagChange(to: newLine, newTags: newTags)
        }

        // Trim trailing whitespace only (not internal spacing)
        newLine = newLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)

        lines[lineNumber - 1] = newLine
        let newContent = lines.joined(separator: "\n")
        try newContent.write(to: fileURL, atomically: true, encoding: .utf8)

        auditLog.logFileModification(
            action: "updateMetadata",
            filePath: filePath,
            lineNumber: lineNumber,
            beforeLine: currentLine,
            afterLine: newLine
        )
    }

    /// Apply a date change to a line for a specific emoji marker.
    /// IMPORTANT: This method preserves the original emoji bytes and spacing verbatim.
    /// It only replaces the date digits (YYYY-MM-DD) to avoid any Unicode encoding
    /// differences that could make Obsidian Tasks unable to find the task line.
    private func applyDateChange(to line: String, emoji: String, emojiUnicode: String, newDate: Date?, formatter: DateFormatter) -> String {
        var newLine = line
        // Match emoji (with optional FE0F variation selector) followed by optional space and date
        let datePattern = "\(emojiUnicode)\u{FE0F}?(\\s*)\\d{4}-\\d{2}-\\d{2}"

        if let date = newDate {
            let dateStr = formatter.string(from: date)
            if let regex = try? NSRegularExpression(pattern: datePattern),
               let match = regex.firstMatch(in: newLine, range: NSRange(newLine.startIndex..., in: newLine)) {
                // Only replace the date digits, preserving the original emoji bytes and spacing
                // Find where the date starts within the match (after emoji + spacing)
                let dateOnlyPattern = "\\d{4}-\\d{2}-\\d{2}"
                if let dateRegex = try? NSRegularExpression(pattern: dateOnlyPattern) {
                    // Search only within the matched range to find the date part
                    if let dateMatch = dateRegex.firstMatch(in: newLine, range: match.range),
                       let dateRange = Range(dateMatch.range, in: newLine) {
                        newLine.replaceSubrange(dateRange, with: dateStr)
                    }
                }
            } else {
                // No existing marker — append emoji + date at end
                let trimmed = newLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                newLine = trimmed + " \(emoji) \(dateStr)"
            }
        } else {
            // Remove the date marker entirely (newDate is nil = remove)
            let removePattern = "\\s*\(emojiUnicode)\u{FE0F}?\\s*\\d{4}-\\d{2}-\\d{2}"
            if let regex = try? NSRegularExpression(pattern: removePattern) {
                let nsRange = NSRange(newLine.startIndex..., in: newLine)
                newLine = regex.stringByReplacingMatches(in: newLine, range: nsRange, withTemplate: "")
            }
        }

        return newLine
    }

    /// Apply a priority change to a line.
    private func applyPriorityChange(to line: String, newPriority: SyncTask.Priority) -> String {
        var newLine = line

        // Remove any existing priority emoji (handle optional FE0F variation selector)
        let priorityEmojis = ["⏫", "🔼", "🔽"]
        for emoji in priorityEmojis {
            if let regex = try? NSRegularExpression(pattern: "\\s*\(emoji)\u{FE0F}?") {
                let nsRange = NSRange(newLine.startIndex..., in: newLine)
                newLine = regex.stringByReplacingMatches(in: newLine, range: nsRange, withTemplate: "")
            }
        }

        // Insert new priority emoji if not .none
        if newPriority != .none {
            let priorityStr = newPriority.obsidianEmoji

            // Insert priority after the checkbox and title, before dates/tags
            let metadataMarkers = ["📅", "🛫", "⏳", "✅", "🔁", "🔂"]
            var insertIndex: String.Index? = nil

            for marker in metadataMarkers {
                if let range = newLine.range(of: marker) {
                    if insertIndex == nil || range.lowerBound < insertIndex! {
                        insertIndex = range.lowerBound
                    }
                }
            }

            if let tagRange = newLine.range(of: " #") {
                if insertIndex == nil || tagRange.lowerBound < insertIndex! {
                    insertIndex = tagRange.lowerBound
                }
            }

            if let idx = insertIndex {
                let prefix = String(newLine[..<idx]).trimmingCharacters(in: .init(charactersIn: " "))
                let suffix = String(newLine[idx...])
                newLine = prefix + " " + priorityStr + " " + suffix
            } else {
                newLine = newLine.trimmingCharacters(in: .init(charactersIn: " ")) + " " + priorityStr
            }
        }

        // Collapse runs of spaces in one pass (was an O(n^2) while-loop). (perf)
        newLine = newLine.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)

        return newLine
    }

    /// Replace tags in a task line with new tags.
    /// Removes all existing #tag and +tag patterns, then appends the new tags.
    private func applyTagChange(to line: String, newTags: [String]) -> String {
        var newLine = line

        // Remove all existing # and + tags
        if let regex = try? NSRegularExpression(pattern: "\\s*[#+][\\w-]+(?:/[\\w-]+)*", options: []) {
            let nsRange = NSRange(newLine.startIndex..., in: newLine)
            newLine = regex.stringByReplacingMatches(in: newLine, range: nsRange, withTemplate: "")
        }

        // Append new tags before metadata emojis
        if !newTags.isEmpty {
            let tagStr = newTags.joined(separator: " ")
            let metadataMarkers = ["📅", "🛫", "⏳", "✅", "🔁", "🔂", "⏫", "🔼", "🔽"]
            var insertIndex: String.Index? = nil

            for marker in metadataMarkers {
                if let range = newLine.range(of: marker) {
                    if insertIndex == nil || range.lowerBound < insertIndex! {
                        insertIndex = range.lowerBound
                    }
                }
            }

            if let idx = insertIndex {
                let prefix = String(newLine[..<idx]).trimmingCharacters(in: .init(charactersIn: " "))
                let suffix = String(newLine[idx...])
                newLine = prefix + " " + tagStr + " " + suffix
            } else {
                newLine = newLine.trimmingCharacters(in: .init(charactersIn: " ")) + " " + tagStr
            }
        }

        // Collapse runs of spaces in one pass (was an O(n^2) while-loop). (perf)
        newLine = newLine.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)

        return newLine
    }

    // MARK: - Recurrence Handling

    /// Parse the recurrence rule from a task line (e.g., "🔁 every month on the 20th when done").
    /// Returns the rule string and whether it's a "when done" rule.
    func parseRecurrenceRule(from line: String) -> (rule: String, whenDone: Bool)? {
        // Match 🔁 (with optional FE0F) followed by the rule text (up to the next emoji or end of line)
        guard let regex = try? NSRegularExpression(
            pattern: "\u{1F501}\u{FE0F}?\\s+(.+?)(?:\\s*[\u{1F4C5}\u{1F6EB}\u{23F3}\u{2705}\u{2B06}\u{FE0F}\u{1F53D}\u{23EB}⏫🔼🔽#]|$)",
            options: []
        ) else { return nil }

        let nsRange = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: nsRange),
              let ruleRange = Range(match.range(at: 1), in: line) else { return nil }

        let rawRule = String(line[ruleRange]).trimmingCharacters(in: .whitespaces)
        let whenDone = rawRule.lowercased().hasSuffix("when done")
        let cleanRule = whenDone
            ? rawRule.replacingOccurrences(of: "when done", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
            : rawRule

        return (rule: cleanRule, whenDone: whenDone)
    }

    /// Result of computing the next recurrence date(s).
    struct RecurrenceResult {
        /// The next reference date (used for due/scheduled/start offset calculations)
        let referenceDate: Date
        /// Optional start date from "on the Nth" rules (e.g., "every month on the 20th")
        let startDate: Date?
    }

    /// Compute the next occurrence date(s) from a recurrence rule.
    ///
    /// For **"when done"** rules:
    /// - The due date advances by the pure interval from the **completion date**
    ///   (e.g., "every month when done", completed Feb 8 → due March 8).
    /// - If the rule includes "on the Nth" (e.g., "every month on the 20th when done"),
    ///   a **start date** is also computed: the next Nth after completion
    ///   (e.g., completed Feb 8 → start Feb 20, due March 8).
    ///
    /// For **non-"when done"** rules:
    /// - Dates advance from the original reference date using the full rule
    ///   (e.g., "every month on the 20th", due Feb 9 → due March 20).
    func computeNextDate(rule: String, whenDone: Bool, referenceDate: Date, completionDate: Date) -> RecurrenceResult? {
        let lowered = rule.lowercased().trimmingCharacters(in: .whitespaces)

        // Remove leading "every " prefix
        guard lowered.hasPrefix("every ") else { return nil }
        let rest = String(lowered.dropFirst(6)).trimmingCharacters(in: .whitespaces)

        let calendar = Calendar.current

        if whenDone {
            return computeNextDateWhenDone(rest: rest, referenceDate: referenceDate, completionDate: completionDate, calendar: calendar)
        } else {
            // Non-"when done": advance from referenceDate using the full rule
            if let next = computeNextOccurrence(rest: rest, baseDate: referenceDate, calendar: calendar) {
                return RecurrenceResult(referenceDate: next, startDate: nil)
            }
            return nil
        }
    }

    /// "When done" computation:
    /// - Due date: advance by pure interval from completionDate (strip "on the Nth")
    /// - Start date: if "on the Nth" present, find next Nth after completionDate
    private func computeNextDateWhenDone(rest: String, referenceDate: Date, completionDate: Date, calendar: Calendar) -> RecurrenceResult? {
        // Check if rule has "on the Nth" modifier
        var startDateFromRule: Date? = nil
        let fullRegex = try? NSRegularExpression(pattern: "^(?:(\\d+)\\s*)?months?\\s+on\\s+the\\s+(.+)$")
        if let fullMatch = fullRegex?.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
            let interval: Int
            if let intRange = Range(fullMatch.range(at: 1), in: rest), let n = Int(String(rest[intRange])) {
                interval = n
            } else {
                interval = 1
            }
            if let dayRange = Range(fullMatch.range(at: 2), in: rest) {
                let dayPart = String(rest[dayRange]).trimmingCharacters(in: .whitespaces)
                startDateFromRule = nextMonthlyOnThe(dayPart: dayPart, interval: interval, after: completionDate, calendar: calendar)
            }
        }

        // Strip "on the ..." suffix to get the pure interval for the due date
        let stripped = rest.replacingOccurrences(
            of: "\\s+on\\s+the\\s+.*$",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        // Advance the due date by the pure interval from completionDate
        if let nextDue = computeNextOccurrence(rest: stripped, baseDate: completionDate, calendar: calendar) {
            return RecurrenceResult(referenceDate: nextDue, startDate: startDateFromRule)
        }
        return nil
    }

    /// Find the next occurrence date after `baseDate` for the given rule text.
    /// The rule text has the "every " prefix already stripped.
    private func computeNextOccurrence(rest: String, baseDate: Date, calendar: Calendar) -> Date? {

        // "every day" / "every N days" / "daily"
        if rest == "day" || rest == "daily" {
            return calendar.date(byAdding: .day, value: 1, to: baseDate)
        }
        if let match = rest.matchFirst(pattern: "^(\\d+)\\s*days?$") {
            if let n = Int(match) {
                return calendar.date(byAdding: .day, value: n, to: baseDate)
            }
        }

        // "every week" / "every N weeks" / "weekly"
        if rest == "week" || rest == "weekly" {
            return calendar.date(byAdding: .weekOfYear, value: 1, to: baseDate)
        }
        if let match = rest.matchFirst(pattern: "^(\\d+)\\s*weeks?$") {
            if let n = Int(match) {
                return calendar.date(byAdding: .weekOfYear, value: n, to: baseDate)
            }
        }

        // "every month on the 20th" / "every 2 months on the last" (for non-"when done" rules)
        // Must check this BEFORE plain "every month" to avoid premature matching.
        if let _ = rest.matchFirst(pattern: "^(?:(\\d+)\\s*)?months?\\s+on\\s+the\\s+(.+)$") {
            let fullRegex = try? NSRegularExpression(pattern: "^(?:(\\d+)\\s*)?months?\\s+on\\s+the\\s+(.+)$")
            if let fullMatch = fullRegex?.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                let interval: Int
                if let intRange = Range(fullMatch.range(at: 1), in: rest), let n = Int(String(rest[intRange])) {
                    interval = n
                } else {
                    interval = 1
                }
                if let dayRange = Range(fullMatch.range(at: 2), in: rest) {
                    let dayPart = String(rest[dayRange]).trimmingCharacters(in: .whitespaces)
                    return nextMonthlyOnThe(dayPart: dayPart, interval: interval, after: baseDate, calendar: calendar)
                }
            }
        }

        // "every month" / "every N months" / "monthly"
        if rest == "month" || rest == "monthly" {
            return calendar.date(byAdding: .month, value: 1, to: baseDate)
        }
        if let match = rest.matchFirst(pattern: "^(\\d+)\\s*months?$") {
            if let n = Int(match) {
                return calendar.date(byAdding: .month, value: n, to: baseDate)
            }
        }

        // "every year" / "every N years" / "yearly" / "annually"
        if rest == "year" || rest == "yearly" || rest == "annually" {
            return calendar.date(byAdding: .year, value: 1, to: baseDate)
        }
        if let match = rest.matchFirst(pattern: "^(\\d+)\\s*years?$") {
            if let n = Int(match) {
                return calendar.date(byAdding: .year, value: n, to: baseDate)
            }
        }

        // "every weekday"
        if rest == "weekday" {
            guard var next = calendar.date(byAdding: .day, value: 1, to: baseDate) else { return nil }
            while calendar.isDateInWeekend(next) {
                guard let following = calendar.date(byAdding: .day, value: 1, to: next) else { return nil }
                next = following
            }
            return next
        }

        // Fallback: couldn't parse — skip recurrence generation
        debugLog("[ObsidianService] Could not parse recurrence rule: 'every \(rest)'")
        return nil
    }

    /// Find the next date matching "on the Nth" / "on the last" after `baseDate`,
    /// advancing by `interval` months at a time.
    private func nextMonthlyOnThe(dayPart: String, interval: Int, after baseDate: Date, calendar: Calendar) -> Date? {
        let baseDateStart = calendar.startOfDay(for: baseDate)

        if dayPart == "last" {
            var candidate = baseDateStart
            for _ in 0..<24 {
                let comps = calendar.dateComponents([.year, .month], from: candidate)
                if let startOfMonth = calendar.date(from: comps),
                   let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: startOfMonth) {
                    if endOfMonth > baseDateStart {
                        return endOfMonth
                    }
                }
                guard let nextCandidate = calendar.date(byAdding: .month, value: interval, to: candidate) else { return nil }
                candidate = nextCandidate
            }
            return nil
        }

        // Parse "20th", "1st", "2nd", "3rd" etc.
        let dayNum = Int(dayPart.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) ?? 1

        var candidate = baseDateStart
        for _ in 0..<24 {
            let comps = calendar.dateComponents([.year, .month], from: candidate)
            let daysInMonth = calendar.range(of: .day, in: .month, for: candidate)?.count ?? 28
            var targetComps = comps
            targetComps.day = min(dayNum, daysInMonth)
            if let targetDate = calendar.date(from: targetComps) {
                if targetDate > baseDateStart {
                    return targetDate
                }
            }
            guard let nextCandidate = calendar.date(byAdding: .month, value: interval, to: candidate) else { return nil }
            candidate = nextCandidate
        }

        return nil
    }

    /// Build the new recurrence line from the original line by:
    /// 1. Keeping `- [ ]` (uncompleted)
    /// 2. Updating all date fields (due, start, scheduled) with the same offset
    /// 3. Removing the completion date (✅)
    /// The original line content is preserved verbatim except for the checkbox, dates, and completion marker.
    func buildRecurrenceLine(originalLine: String, nextDueDate: Date?, nextStartDate: Date?, nextScheduledDate: Date?) -> String {
        var newLine = originalLine

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        // Ensure uncompleted checkbox
        if let range = newLine.range(of: "- [x]") {
            newLine.replaceSubrange(range, with: "- [ ]")
        } else if let range = newLine.range(of: "- [X]") {
            newLine.replaceSubrange(range, with: "- [ ]")
        }

        // Update due date 📅 — only replace the date digits, preserving original emoji bytes
        if let next = nextDueDate {
            let dateStr = formatter.string(from: next)
            newLine = replaceDateOnly(in: newLine, emojiUnicode: "\u{1F4C5}", newDateStr: dateStr)
        }

        // Update start date 🛫 (or insert if not present)
        if let next = nextStartDate {
            let dateStr = formatter.string(from: next)
            let startPattern = "\u{1F6EB}\u{FE0F}?\\s*\\d{4}-\\d{2}-\\d{2}"
            if let regex = try? NSRegularExpression(pattern: startPattern),
               regex.firstMatch(in: newLine, range: NSRange(newLine.startIndex..., in: newLine)) != nil {
                // Replace only the date digits, preserving original emoji bytes
                newLine = replaceDateOnly(in: newLine, emojiUnicode: "\u{1F6EB}", newDateStr: dateStr)
            } else {
                // Insert start date before due date (📅) if present, otherwise append
                if let dueRange = newLine.range(of: "\u{1F4C5}") ?? newLine.range(of: "📅") {
                    newLine.insert(contentsOf: "🛫 \(dateStr) ", at: dueRange.lowerBound)
                } else {
                    newLine += " 🛫 \(dateStr)"
                }
            }
        }

        // Update scheduled date ⏳ — only replace the date digits
        if let next = nextScheduledDate {
            let dateStr = formatter.string(from: next)
            newLine = replaceDateOnly(in: newLine, emojiUnicode: "\u{23F3}", newDateStr: dateStr)
        }

        // Remove completion date ✅ — handle optional FE0F variation selector
        if let regex = try? NSRegularExpression(pattern: "\\s*\u{2705}\u{FE0F}?\\s*\\d{4}-\\d{2}-\\d{2}") {
            let nsRange = NSRange(newLine.startIndex..., in: newLine)
            newLine = regex.stringByReplacingMatches(in: newLine, range: nsRange, withTemplate: "")
        }

        return newLine
    }

    // MARK: - Safe Date Replacement Helper

    /// Replace ONLY the date digits (YYYY-MM-DD) within an emoji+date marker,
    /// preserving the original emoji bytes, variation selectors, and spacing verbatim.
    /// This prevents Obsidian Tasks from failing to find the task line after we edit it.
    private func replaceDateOnly(in line: String, emojiUnicode: String, newDateStr: String) -> String {
        let pattern = "\(emojiUnicode)\u{FE0F}?\\s*\\d{4}-\\d{2}-\\d{2}"
        guard let emojiRegex = try? NSRegularExpression(pattern: pattern),
              let emojiMatch = emojiRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return line
        }

        // Find the date-only portion within the matched range
        let datePattern = "\\d{4}-\\d{2}-\\d{2}"
        guard let dateRegex = try? NSRegularExpression(pattern: datePattern),
              let dateMatch = dateRegex.firstMatch(in: line, range: emojiMatch.range),
              let dateRange = Range(dateMatch.range, in: line) else {
            return line
        }

        var result = line
        result.replaceSubrange(dateRange, with: newDateStr)
        return result
    }

    // MARK: - File Change Detection

    /// Capture modification timestamps for files that may be written to.
    func captureFileTimestamp(filePath: String, vaultPath: String) -> Date? {
        let url = URL(fileURLWithPath: vaultPath + filePath)
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return nil
        }
        return modDate
    }

    /// Check if a file has been modified since a given timestamp.
    func hasFileChanged(filePath: String, since timestamp: Date, vaultPath: String) -> Bool {
        let url = URL(fileURLWithPath: vaultPath + filePath)
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return true // Can't check — assume changed (safe default)
        }
        return modDate > timestamp
    }

    // MARK: - Deprecated Dangerous Methods (disabled for safety)

    /// DISABLED: This method used toObsidianLine() which destroys metadata.
    /// Use markTaskComplete() or markTaskIncomplete() for safe edits.
    @available(*, deprecated, message: "Unsafe: rewrites entire line. Use markTaskComplete() instead.")
    func updateTask(_ task: SyncTask, vaultPath: String) throws {
        throw ObsidianError.unsafeWriteDisabled
    }

    /// DISABLED: This method used toObsidianLine() which destroys metadata.
    @available(*, deprecated, message: "Unsafe: rewrites entire line via toObsidianLine().")
    func addTask(_ task: SyncTask, toFile relativePath: String, vaultPath: String) throws -> SyncTask {
        throw ObsidianError.unsafeWriteDisabled
    }

    /// DISABLED: This method could corrupt line numbers for other tasks.
    @available(*, deprecated, message: "Unsafe: line removal corrupts sync state.")
    func deleteTask(_ task: SyncTask, vaultPath: String, keepCommented: Bool = false) throws {
        throw ObsidianError.unsafeWriteDisabled
    }

    // MARK: - File Discovery

    private func findMarkdownFiles(in directory: URL, excluding excludedFolders: [String], including includedFolders: [String] = []) throws -> [URL] {
        let vaultPath = directory.path
        let useWhitelist = !includedFolders.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).isEmpty

        // If whitelist mode, scan only the specified folders (+ root-level .md files)
        if useWhitelist {
            debugLog("[ObsidianService] Whitelist mode: scanning only \(includedFolders)")
            var files: [URL] = []

            // Scan root-level .md files (e.g., Inbox.md)
            if let rootContents = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) {
                for item in rootContents {
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if !isDir && item.pathExtension.lowercased() == "md" {
                        files.append(item)
                    }
                }
            }

            // Scan each whitelisted folder
            for folder in includedFolders {
                let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                guard !trimmed.isEmpty else { continue }
                let folderURL = directory.appendingPathComponent(trimmed)
                guard fileManager.fileExists(atPath: folderURL.path) else {
                    debugLog("[ObsidianService] Whitelist folder not found: \(trimmed)")
                    continue
                }
                // Recursively scan this folder (excluding standard hidden folders)
                let subFiles = try findMarkdownFilesRecursive(in: folderURL, excluding: excludedFolders, vaultPath: vaultPath)
                files.append(contentsOf: subFiles)
            }
            return files
        }

        // Default mode: scan everything, excluding specified folders
        var files: [URL] = []

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            throw ObsidianError.cannotEnumerateDirectory(directory.path)
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            let name = resourceValues.name ?? ""

            if resourceValues.isDirectory == true {
                let relativePath = String(fileURL.path.dropFirst(vaultPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                let shouldExclude = excludedFolders.contains(where: { excluded in
                    let trimmed = excluded.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    guard !trimmed.isEmpty else { return false }
                    return name == trimmed
                        || relativePath == trimmed
                        || relativePath.hasPrefix(trimmed + "/")
                })

                if shouldExclude {
                    debugLog("[ObsidianService] Excluding folder: \(relativePath)")
                    enumerator.skipDescendants()
                }
                continue
            }

            if fileURL.pathExtension.lowercased() == "md" {
                files.append(fileURL)
            }
        }

        return files
    }

    /// Recursively scan a folder for .md files, respecting exclusions.
    private func findMarkdownFilesRecursive(in directory: URL, excluding excludedFolders: [String], vaultPath: String) throws -> [URL] {
        var files: [URL] = []
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles]
        ) else { return files }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            if resourceValues.isDirectory == true {
                let name = resourceValues.name ?? ""
                let shouldExclude = excludedFolders.contains(where: { excluded in
                    let trimmed = excluded.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    guard !trimmed.isEmpty else { return false }
                    return name == trimmed
                })
                if shouldExclude { enumerator.skipDescendants() }
                continue
            }
            if fileURL.pathExtension.lowercased() == "md" {
                files.append(fileURL)
            }
        }
        return files
    }

    // MARK: - Utility

    /// Get the default tasks file path based on configuration
    func getDefaultTasksFile(for listName: String) -> String {
        return "Tasks/\(listName).md"
    }
}

// MARK: - String Regex Helper

private extension String {
    /// Return the first capture group from a regex match, or nil.
    func matchFirst(pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, range: nsRange) else { return nil }
        // Return last capture group (the most specific one)
        for i in stride(from: match.numberOfRanges - 1, through: 1, by: -1) {
            if let range = Range(match.range(at: i), in: self) {
                return String(self[range])
            }
        }
        return nil
    }
}

// MARK: - Errors

enum ObsidianError: LocalizedError {
    case vaultNotFound(String)
    case cannotEnumerateDirectory(String)
    case noSourceInformation
    case lineNumberOutOfRange(Int, Int)
    case fileNotFound(String)
    case lineContentMismatch(expected: String, found: String)
    case fileModifiedDuringSync
    case unsafeWriteDisabled

    var errorDescription: String? {
        switch self {
        case .vaultNotFound(let path):
            return "Obsidian vault not found at: \(path)"
        case .cannotEnumerateDirectory(let path):
            return "Cannot enumerate directory: \(path)"
        case .noSourceInformation:
            return "Task has no Obsidian source information"
        case .lineNumberOutOfRange(let line, let total):
            return "Line number \(line) is out of range (file has \(total) lines)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .lineContentMismatch(expected: let expected, found: let found):
            return "File has changed since last scan. Expected line content doesn't match current content. Expected: \(expected.prefix(50))... Found: \(found.prefix(50))..."
        case .fileModifiedDuringSync:
            return "File was modified during sync operation. Skipping write for safety."
        case .unsafeWriteDisabled:
            return "This write method has been disabled for safety. It previously caused data loss by reconstructing task lines and losing metadata."
        }
    }
}
