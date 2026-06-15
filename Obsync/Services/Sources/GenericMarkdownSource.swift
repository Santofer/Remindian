import Foundation

/// Generic Markdown task source (#27) — reads plain-markdown task tools such as
/// NotePlan via a configurable token dialect (`config.genericMarkdown`).
///
/// Fully self-contained: it uses `GenericMarkdownParser` and its own file I/O,
/// never the Obsidian-Tasks emoji parser or `ObsidianService`. The vault is
/// still the source of truth; writeback is surgical (completion, metadata,
/// new-task append) and verifies the original line before editing so a
/// concurrent external edit aborts the write rather than clobbering it.
class GenericMarkdownSource: TaskSource {
    let sourceName = "Generic Markdown"

    private let fileManager = FileManager.default
    private let backupService = FileBackupService.shared

    // MARK: - Scanning

    func scanTasks(config: SyncConfiguration) throws -> [SyncTask] {
        let settings = config.genericMarkdown
        let parser = GenericMarkdownParser(settings: settings)
        let ignoredMarkers = Set(config.obsidianTasksIgnoredMarkers.compactMap { $0.first })
        let exts = Set(settings.fileExtensions.map { $0.lowercased().replacingOccurrences(of: ".", with: "") })

        let vaultURL = URL(fileURLWithPath: config.vaultPath)
        guard fileManager.fileExists(atPath: config.vaultPath) else {
            throw ObsidianError.vaultNotFound(config.vaultPath)
        }

        let files = try findFiles(in: vaultURL, extensions: exts,
                                  excluding: config.excludedFolders, including: config.includedFolders)
        var tasks: [SyncTask] = []
        for fileURL in files {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: config.vaultPath, with: "")
            let lines = content.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if let task = parser.parse(line, filePath: relativePath, lineNumber: index + 1, ignoredMarkers: ignoredMarkers) {
                    tasks.append(task)
                }
            }
        }

        // Global filter (#42) — same opt-in semantics as the Obsidian source:
        // only sync lines containing the global filter tag.
        let globalFilter = config.globalFilter.trimmingCharacters(in: .whitespaces)
        if !globalFilter.isEmpty {
            tasks = tasks.filter { task in
                (task.obsidianSource?.originalLine ?? "").contains(globalFilter)
            }
        }
        return tasks
    }

    func generateTaskId(for task: SyncTask) -> String {
        SyncState.generateObsidianId(task: task)
    }

    // MARK: - Writeback (surgical)

    @discardableResult
    func markTaskComplete(task: SyncTask, completionDate: Date, config: SyncConfiguration) throws -> Int {
        let parser = GenericMarkdownParser(settings: config.genericMarkdown)
        try surgicallyEdit(task: task, vaultPath: config.vaultPath) { line in
            parser.markComplete(line: line, completionDate: completionDate)
        }
        return 0
    }

    func markTaskIncomplete(task: SyncTask, config: SyncConfiguration) throws {
        let parser = GenericMarkdownParser(settings: config.genericMarkdown)
        try surgicallyEdit(task: task, vaultPath: config.vaultPath) { line in
            parser.markIncomplete(line: line)
        }
    }

    func updateTaskMetadata(task: SyncTask, changes: MetadataChanges, config: SyncConfiguration) throws {
        guard changes.hasChanges else { return }
        let parser = GenericMarkdownParser(settings: config.genericMarkdown)
        try surgicallyEdit(task: task, vaultPath: config.vaultPath) { line in
            parser.updateMetadata(
                line: line,
                newDueDate: changes.newDueDate,
                newStartDate: changes.newStartDate,
                newPriority: changes.newPriority,
                newTags: changes.newTags
            )
        }
    }

    func appendNewTask(_ task: SyncTask, config: SyncConfiguration) throws -> SyncTask.ObsidianSource {
        let parser = GenericMarkdownParser(settings: config.genericMarkdown)
        let taskLine = parser.buildLine(from: task)

        // Resolve the inbox path; default to Inbox with the first configured
        // extension if the configured inbox path is empty.
        var inboxRelative = config.inboxFilePath.trimmingCharacters(in: .whitespaces)
        if inboxRelative.isEmpty {
            let ext = config.genericMarkdown.fileExtensions.first ?? "md"
            inboxRelative = "Inbox.\(ext)"
        }
        let normalizedRelative = inboxRelative.hasPrefix("/") ? inboxRelative : "/\(inboxRelative)"
        let url = URL(fileURLWithPath: config.vaultPath + normalizedRelative)

        // Create the inbox file if missing.
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: url, atomically: true, encoding: .utf8)
        } else {
            _ = try? backupService.backupFile(at: url)
        }

        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += taskLine + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)

        let lineNumber = content.components(separatedBy: "\n").count - 1 // last non-empty line
        return SyncTask.ObsidianSource(filePath: normalizedRelative, lineNumber: lineNumber, originalLine: taskLine)
    }

    func hasFileChanged(task: SyncTask, since timestamp: Date, config: SyncConfiguration) -> Bool {
        guard let source = task.obsidianSource else { return true }
        let url = URL(fileURLWithPath: config.vaultPath + source.filePath)
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else {
            return true // can't check → assume changed (safe)
        }
        return modDate > timestamp
    }

    // MARK: - Internals

    /// Read the file, locate the task's line, apply `transform` to that one line,
    /// and write back atomically (with a backup).
    ///
    /// The stored line index may be stale — a prior sync, an iCloud re-sync, or an
    /// edit in the editor itself may have shifted lines since the scan that produced
    /// `source.lineNumber`. So we relocate by content: the exact recorded line at
    /// the stored index first (the fast path), then the exact recorded line anywhere
    /// (it simply moved). If the line is gone in its recorded form (e.g. the task was
    /// completed elsewhere since the scan), this is a safe no-op — we never throw a
    /// "file changed" error and never edit a line we can't positively identify. (#75-followup)
    private func surgicallyEdit(task: SyncTask, vaultPath: String, transform: (String) -> String) throws {
        guard let source = task.obsidianSource else { throw ObsidianError.noSourceInformation }
        let url = URL(fileURLWithPath: vaultPath + source.filePath)
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")

        let expected = source.originalLine.trimmingCharacters(in: .whitespaces)
        let storedIdx = source.lineNumber - 1
        let idx: Int
        if storedIdx >= 0, storedIdx < lines.count,
           lines[storedIdx].trimmingCharacters(in: .whitespaces) == expected {
            idx = storedIdx
        } else if let found = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == expected
        }) {
            idx = found
        } else {
            // Task line not present in its expected form — nothing safe to edit.
            return
        }

        let newLine = transform(lines[idx])
        guard newLine != lines[idx] else { return } // no-op, skip the write

        _ = try? backupService.backupFile(at: url)
        lines[idx] = newLine
        let newContent = lines.joined(separator: "\n")
        try newContent.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Enumerate files with the configured extensions, honoring include/exclude
    /// folders. Mirrors the Obsidian scanner's filtering semantics.
    private func findFiles(in directory: URL, extensions: Set<String>, excluding excludedFolders: [String], including includedFolders: [String]) throws -> [URL] {
        let vaultPath = directory.path
        let whitelist = includedFolders.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let useWhitelist = !whitelist.isEmpty

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles]) else {
            throw ObsidianError.cannotEnumerateDirectory(directory.path)
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            let name = values.name ?? ""
            if values.isDirectory == true {
                let relativePath = String(fileURL.path.dropFirst(vaultPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let shouldExclude = excludedFolders.contains { excluded in
                    let trimmed = excluded.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    guard !trimmed.isEmpty else { return false }
                    return name == trimmed || relativePath == trimmed || relativePath.hasPrefix(trimmed + "/")
                }
                if shouldExclude { enumerator.skipDescendants() }
                continue
            }
            guard extensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            if useWhitelist {
                let relativePath = String(fileURL.path.dropFirst(vaultPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let inWhitelist = whitelist.contains { folder in
                    let trimmed = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    return !relativePath.contains("/") || relativePath.hasPrefix(trimmed + "/")
                }
                guard inWhitelist else { continue }
            }
            files.append(fileURL)
        }
        return files
    }
}
