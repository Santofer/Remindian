import Foundation
import AppKit

/// Things 3 destination using AppleScript (read) + URL scheme (write).
///
/// Architecture:
/// - READ: AppleScript via NSAppleScript for task properties (id, name, notes, due date, status, tags, project, area)
/// - CREATE: AppleScript-based creation for reliable task ID retrieval
/// - UPDATE: things:// URL scheme update command with auth-token
/// - DETECT CHANGES: Poll via AppleScript (no push mechanism in Things 3)
///
/// Limitations:
/// - Start date ("When") not readable via AppleScript (would need SQLite for that)
/// - Recurrence rules are read-only (only accessible via SQLite, not modifiable via any API)
/// - Auth token required for updates (user must provide from Things > Settings > General)
/// - No push/webhook — must poll for changes
/// - Checklist items not accessible via AppleScript
class Things3Destination: TaskDestination {
    let destinationName = "Things 3"

    /// The auth token from Things > Settings > General > Enable Things URLs > Manage
    var authToken: String = ""

    /// Optional progress callback set by the sync engine. Called with short
    /// human-readable strings during long-running fetch operations so the UI
    /// can show which list is currently being processed (#56).
    var progressCallback: ((String) -> Void)? = nil

    /// Non-fatal errors encountered during the most recent `fetchAllTasks` call.
    /// When an individual list times out, we skip it and continue with other
    /// lists (partial sync is better than no sync). The sync engine reads this
    /// after `fetchAllTasks` and surfaces the warnings without aborting. (#56)
    private(set) var lastFetchWarnings: [Error] = []

    /// Clean tags for Things 3 — strip # prefix, extract leaf from hierarchy.
    /// Things 3 URL scheme requires tags to match existing tag titles exactly.
    /// For hierarchical tags like "person/name", the URL scheme needs just the
    /// leaf component ("name") — Things 3 resolves the hierarchy natively.
    /// Sending the full path gets percent-encoded (person%2Fname) and won't match.
    internal func cleanTagsForThings(_ tags: [String]) -> [String] {
        var cleaned: [String] = []
        var seen = Set<String>()
        for tag in tags {
            let stripped = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
            guard !stripped.isEmpty else { continue }
            // Extract leaf tag name for hierarchical tags (e.g. "person/name" → "name")
            let leaf = stripped.components(separatedBy: "/").last ?? stripped
            guard !leaf.isEmpty, seen.insert(leaf).inserted else { continue }
            cleaned.append(leaf)
        }
        return cleaned
    }

    /// Build the `tag names:"..."` AppleScript property fragment for Things 3.
    /// Returns an empty string when there are no tags.
    ///
    /// See #59: Things 3's scripting dictionary declares `tag names` as TEXT, so
    /// list syntax (`{"a", "b"}`) fails with error -1700 when 2+ tags are present.
    /// Always use comma-separated string form. Fix by @joscdk in PR #60.
    internal func buildTagNamesProperty(tags: [String]) -> String {
        let tagNames = cleanTagsForThings(tags)
        guard !tagNames.isEmpty else { return "" }
        let tagString = tagNames
            .map { $0.replacingOccurrences(of: "\"", with: "\\\"") }
            .joined(separator: ", ")
        return "tag names:\"\(tagString)\""
    }

    // Cache for performance
    private var cachedLists: [String] = []
    private var lastListRefresh: Date?

    /// Build obsidian:// deep link for a task, to embed in Things 3 notes.
    private func buildObsidianLink(task: SyncTask, config: SyncConfiguration) -> String? {
        guard config.addTaskLinkToReminders,
              let source = task.obsidianSource,
              !config.vaultPath.isEmpty else { return nil }
        let vaultName = URL(fileURLWithPath: config.vaultPath).lastPathComponent
        let encodedVault = vaultName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? vaultName
        let encodedFile = source.filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? source.filePath
        return "obsidian://open?vault=\(encodedVault)&file=\(encodedFile)"
    }

    /// Prepend obsidian:// link to notes if configured.
    private func notesWithObsidianLink(task: SyncTask, config: SyncConfiguration) -> String {
        let baseNotes = task.notes ?? ""
        guard let link = buildObsidianLink(task: task, config: config) else {
            return baseNotes
        }
        if baseNotes.isEmpty {
            return link
        }
        return link + "\n\n" + baseNotes
    }

    // MARK: - Authorization

    func requestAccess() async throws -> Bool {
        // Things 3 doesn't require explicit permission — we just need to check if it's installed
        guard isThings3Installed() else {
            throw Things3Error.notInstalled
        }

        // Test AppleScript access — use bundle ID for reliable resolution in sandbox
        // Uses 10s timeout to prevent hanging if Things 3 is unresponsive
        let testScriptSource = """
            tell application id "com.culturedcode.ThingsMac"
                return name
            end tell
        """
        do {
            let result = try await executeAppleScript(testScriptSource, timeout: 10)
            return result != nil
        } catch Things3Error.appleScriptTimeout {
            throw Things3Error.appleScriptTimeout
        } catch Things3Error.notAuthorized {
            // Surface the actionable Automation-permission guidance verbatim
            // rather than the generic "access denied". (#56)
            throw Things3Error.notAuthorized
        } catch {
            throw Things3Error.appleScriptAccessDenied
        }
    }

    // MARK: - Fetching

    func fetchAllTasks() async throws -> [SyncTask] {
        // Reset warnings for this fetch cycle.
        lastFetchWarnings = []

        var tasks: [SyncTask] = []
        // Track per-list failures so we can surface a clear error after a
        // successful partial sync. Before #56 follow-up, a single list timeout
        // aborted the whole fetch and the user lost every list + Logbook.
        // Now we continue with whatever lists respond and report the failures.
        var listFailures: [(listName: String, error: Error)] = []

        // Fetch from active lists
        let activeLists = ["Today", "Inbox", "Anytime", "Upcoming", "Someday"]
        for listName in activeLists {
            progressCallback?("Fetching Things 3 (\(listName))…")
            let listStart = Date()
            do {
                let listTasks = try await fetchTasksFromList(listName)
                let elapsed = Date().timeIntervalSince(listStart)
                debugLog("[Things3] Fetched \(listTasks.count) tasks from '\(listName)' in \(String(format: "%.2f", elapsed))s")
                tasks.append(contentsOf: listTasks)
            } catch Things3Error.notAuthorized {
                // Automation permission denied → every list and the Logbook will
                // fail identically, and returning an empty task set would make
                // the engine think Things 3 was wiped. Abort the whole fetch now
                // with the actionable message instead of grinding through all of
                // them and silently reporting "empty". (#56)
                debugLog("[Things3] Not authorized to control Things 3 — aborting fetch with actionable error.")
                throw Things3Error.notAuthorized
            } catch {
                let elapsed = Date().timeIntervalSince(listStart)
                debugLog("[Things3] Failed to fetch '\(listName)' after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
                listFailures.append((listName: listName, error: error))
                // Continue with other lists — partial data is better than none.
            }
        }

        // Fetch recently completed tasks from Logbook.
        progressCallback?("Fetching Things 3 (Logbook, last 7 days)…")
        let logbookStart = Date()
        do {
            let logbookTasks = try await fetchRecentLogbookTasks(withinDays: 7)
            let elapsed = Date().timeIntervalSince(logbookStart)
            debugLog("[Things3] Fetched \(logbookTasks.count) Logbook tasks in \(String(format: "%.2f", elapsed))s")
            tasks.append(contentsOf: logbookTasks)
        } catch {
            let elapsed = Date().timeIntervalSince(logbookStart)
            debugLog("[Things3] Failed to fetch Logbook after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)")
            listFailures.append((listName: "Logbook", error: error))
        }

        // If every list failed, there's nothing to sync — surface the first error
        // so the user sees a clear failure instead of a silent no-op.
        if tasks.isEmpty, let first = listFailures.first {
            throw first.error
        }

        // Partial success: store warnings so the sync engine can surface them
        // (one per failed list) without aborting the whole sync.
        if !listFailures.isEmpty {
            let failedNames = listFailures.map { $0.listName }.joined(separator: ", ")
            debugLog("[Things3] Partial fetch: \(listFailures.count) list(s) failed (\(failedNames)), \(tasks.count) tasks fetched from surviving lists.")
            lastFetchWarnings = listFailures.map { failure in
                Things3Error.listFetchFailed(listName: failure.listName, underlying: failure.error.localizedDescription)
            }
        }

        return tasks
    }

    func getAvailableLists() async -> [String] {
        // Refresh cache every 60 seconds
        if let lastRefresh = lastListRefresh, Date().timeIntervalSince(lastRefresh) < 60 {
            return cachedLists
        }

        var lists = ["Inbox", "Today", "Anytime", "Upcoming", "Someday"]

        // Fetch projects and areas via AppleScript (with 15s timeout)
        let scriptSource = """
            tell application id "com.culturedcode.ThingsMac"
                set projectNames to {}
                repeat with p in projects
                    set end of projectNames to name of p
                end repeat
                set areaNames to {}
                repeat with a in areas
                    set end of areaNames to name of a
                end repeat
                return {projectNames, areaNames}
            end tell
        """

        if let result = try? await executeAppleScript(scriptSource, timeout: 15) {
            // Parse the AppleScript result
            if result.numberOfItems >= 2 {
                // Projects
                if let projects = result.atIndex(1) {
                    for i in 1...max(1, projects.numberOfItems) {
                        if let name = projects.atIndex(i)?.stringValue {
                            lists.append("\u{1F4C1} \(name)")
                        }
                    }
                }
                // Areas
                if let areas = result.atIndex(2) {
                    for i in 1...max(1, areas.numberOfItems) {
                        if let name = areas.atIndex(i)?.stringValue {
                            lists.append("\u{1F4C2} \(name)")
                        }
                    }
                }
            }
        } else {
            debugLog("[Things3] Timed out or failed fetching projects/areas, using default lists")
        }

        cachedLists = lists
        lastListRefresh = Date()
        return lists
    }

    // MARK: - CRUD

    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        // Use AppleScript to create task — more reliable than URL scheme for getting the task ID back
        let cleanList = listName
            .replacingOccurrences(of: "\u{1F4C1} ", with: "")
            .replacingOccurrences(of: "\u{1F4C2} ", with: "")

        let escapedTitle = task.title.replacingOccurrences(of: "\"", with: "\\\"")
        let fullNotes = notesWithObsidianLink(task: task, config: config)
        let escapedNotes = fullNotes.replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        // Build properties — due date is set via AppleScript date component construction
        // to avoid locale-dependent date literal parsing issues
        var properties = "name:\"\(escapedTitle)\""
        if !escapedNotes.isEmpty {
            properties += ", notes:\"\(escapedNotes)\""
        }
        if task.isCompleted {
            properties += ", status:completed"
        }
        // Embed tags directly in AppleScript properties (#speed).
        // See buildTagNamesProperty — text form, not list, per #59 fix (@joscdk).
        let tagProp = buildTagNamesProperty(tags: task.tags)
        if !tagProp.isEmpty {
            properties += ", \(tagProp)"
        }

        // Build a locale-independent due date setter using AppleScript date components
        var dueDateScript = ""
        if let dueDate = task.dueDate {
            let cal = Calendar.current
            let y = cal.component(.year, from: dueDate)
            let m = cal.component(.month, from: dueDate)
            let d = cal.component(.day, from: dueDate)
            dueDateScript = """
                    set dueD to current date
                    set year of dueD to \(y)
                    set month of dueD to \(m)
                    set day of dueD to \(d)
                    set time of dueD to 0
                    set due date of newTodo to dueD
            """
        }

        // Build the creation script
        var scriptSource: String
        if listName.hasPrefix("\u{1F4C1} ") {
            // Create in a project
            let escapedProject = cleanList.replacingOccurrences(of: "\"", with: "\\\"")
            scriptSource = """
                tell application id "com.culturedcode.ThingsMac"
                    set newTodo to make new to do with properties {\(properties)}
                    move newTodo to project "\(escapedProject)"
                \(dueDateScript)
                    return id of newTodo
                end tell
            """
        } else {
            scriptSource = """
                tell application id "com.culturedcode.ThingsMac"
                    set newTodo to make new to do with properties {\(properties)}
                \(dueDateScript)
                    return id of newTodo
                end tell
            """
        }

        // Execute with retry + 30s timeout — sandbox AppleScript can race against app initialization
        guard let result = try await executeAppleScriptWithRetryAndTimeout(source: scriptSource),
              let taskId = result.stringValue, !taskId.isEmpty else {
            throw Things3Error.appleScriptError("Failed to create task: no ID returned")
        }

        // Tags are now embedded in AppleScript properties — no URL scheme needed for creation

        debugLog("[Things3] Created task \"\(task.title)\" with id=\(taskId)")
        return taskId
    }

    /// Batch-create multiple tasks in a single AppleScript call for performance.
    /// Returns an array of Things 3 task IDs in the same order as the input.
    func createTasksBatch(tasks: [(task: SyncTask, listName: String)], config: SyncConfiguration) async throws -> [String] {
        guard !tasks.isEmpty else { return [] }

        // Build a single AppleScript that creates all tasks and returns their IDs
        var scriptLines = [
            "tell application id \"com.culturedcode.ThingsMac\"",
            "    set idList to {}"
        ]

        for (task, listName) in tasks {
            let escapedTitle = task.title.replacingOccurrences(of: "\"", with: "\\\"")
            let fullNotes = notesWithObsidianLink(task: task, config: config)
            let escapedNotes = fullNotes.replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")

            var properties = "name:\"\(escapedTitle)\""
            if !escapedNotes.isEmpty {
                properties += ", notes:\"\(escapedNotes)\""
            }
            if task.isCompleted {
                properties += ", status:completed"
            }

            // Embed tags directly in AppleScript to avoid per-task URL scheme calls (#speed).
            // See buildTagNamesProperty — text form, not list, per #59 fix (@joscdk).
            let tagProp = buildTagNamesProperty(tags: task.tags)
            if !tagProp.isEmpty {
                properties += ", \(tagProp)"
            }

            scriptLines.append("    set newTodo to make new to do with properties {\(properties)}")

            // Move to project if needed
            let cleanList = listName
                .replacingOccurrences(of: "\u{1F4C1} ", with: "")
                .replacingOccurrences(of: "\u{1F4C2} ", with: "")
            if listName.hasPrefix("\u{1F4C1} ") {
                let escapedProject = cleanList.replacingOccurrences(of: "\"", with: "\\\"")
                scriptLines.append("    move newTodo to project \"\(escapedProject)\"")
            }

            // Set due date using locale-independent date components
            if let dueDate = task.dueDate {
                let cal = Calendar.current
                let y = cal.component(.year, from: dueDate)
                let m = cal.component(.month, from: dueDate)
                let d = cal.component(.day, from: dueDate)
                scriptLines.append("    set dueD to current date")
                scriptLines.append("    set year of dueD to \(y)")
                scriptLines.append("    set month of dueD to \(m)")
                scriptLines.append("    set day of dueD to \(d)")
                scriptLines.append("    set time of dueD to 0")
                scriptLines.append("    set due date of newTodo to dueD")
            }

            scriptLines.append("    set end of idList to id of newTodo")
        }

        scriptLines.append("    set AppleScript's text item delimiters to \"|||\"")
        scriptLines.append("    return idList as string")
        scriptLines.append("end tell")

        let scriptSource = scriptLines.joined(separator: "\n")
        guard let result = try await executeAppleScriptWithRetryAndTimeout(source: scriptSource),
              let resultString = result.stringValue, !resultString.isEmpty else {
            throw Things3Error.appleScriptError("Batch create failed: no IDs returned")
        }

        let ids = resultString.components(separatedBy: "|||")
        guard ids.count == tasks.count else {
            throw Things3Error.appleScriptError("Batch create returned \(ids.count) IDs for \(tasks.count) tasks")
        }

        // Tags are now set directly in the AppleScript properties above — no URL scheme needed

        debugLog("[Things3] Batch created \(tasks.count) tasks (tags embedded in AppleScript)")
        return ids
    }

    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        guard !authToken.isEmpty else {
            // Don't throw — allow sync to continue for creation-only workflows.
            // Updates require the auth token, but new tasks are created via AppleScript.
            debugLog("[Things3] Skipping update for \"\(task.title)\" — no auth token configured. Go to Things > Settings > General > Enable Things URLs to get your token.")
            return
        }

        var params: [String: String] = [
            "id": id,
            "auth-token": authToken
        ]

        params["title"] = task.title

        if let dueDate = task.dueDate {
            params["deadline"] = formatDate(dueDate)
        } else {
            params["deadline"] = "" // Clear deadline
        }

        if task.isCompleted {
            params["completed"] = "true"
        }

        let fullNotes = notesWithObsidianLink(task: task, config: config)
        if !fullNotes.isEmpty {
            params["notes"] = fullNotes
        }

        // Sync tags (#32 — tag changes were not being sent to Things 3)
        // Clean tags for Things 3 — strip # prefix, preserve hierarchy (#45)
        if !task.tags.isEmpty {
            let tagNames = cleanTagsForThings(task.tags)
            params["tags"] = tagNames.joined(separator: ",")
        }

        var components = URLComponents()
        components.scheme = "things"
        components.host = ""
        components.path = "/update"
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw Things3Error.invalidURL
        }

        let success = NSWorkspace.shared.open(url)
        if !success {
            throw Things3Error.urlSchemeNotHandled
        }

        // Throttle: give Things 3 time to process the URL scheme call
        // before firing the next one — rapid-fire calls overwhelm it
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }

    func moveTask(withId id: String, toList listName: String) async throws {
        guard !authToken.isEmpty else {
            debugLog("[Things3] Skipping move — no auth token configured")
            return
        }

        let cleanList = listName
            .replacingOccurrences(of: "\u{1F4C1} ", with: "")
            .replacingOccurrences(of: "\u{1F4C2} ", with: "")

        var params: [String: String] = [
            "id": id,
            "auth-token": authToken,
            "list": cleanList
        ]

        var components = URLComponents()
        components.scheme = "things"
        components.host = ""
        components.path = "/update"
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw Things3Error.invalidURL
        }

        let success = NSWorkspace.shared.open(url)
        if !success {
            throw Things3Error.urlSchemeNotHandled
        }
    }

    func deleteTask(withId id: String) async throws {
        // Things 3 URL scheme doesn't support deletion.
        // Use AppleScript to move to Trash instead (with 30s timeout).
        // Error -1728 ("Can't get to do id X") means the task is already gone —
        // swallow it so stale sync state doesn't surface as a user-visible error.
        let scriptSource = """
            tell application id "com.culturedcode.ThingsMac"
                try
                    set theTodo to to do id "\(id)"
                    delete theTodo
                on error errMsg number errNum
                    if errNum is not -1728 then error errMsg number errNum
                end try
            end tell
        """

        _ = try await executeAppleScriptWithRetryAndTimeout(source: scriptSource)
    }

    func refresh() {
        cachedLists = []
        lastListRefresh = nil
    }

    // MARK: - AppleScript Helpers

    /// Execute an AppleScript with one retry on failure and a timeout to prevent indefinite blocking.
    /// If the first attempt fails (e.g., app not initialized), we retry once with a
    /// `launch` preamble to ensure Things 3 is running. Both attempts are capped by the timeout.
    private func executeAppleScriptWithRetryAndTimeout(source: String, timeout: TimeInterval = 30) async throws -> NSAppleEventDescriptor? {
        do {
            return try await executeAppleScript(source, timeout: timeout)
        } catch Things3Error.appleScriptTimeout {
            throw Things3Error.appleScriptTimeout
        } catch Things3Error.notAuthorized {
            // Permission denial — retrying is pointless and just makes the sync
            // feel stuck. Fail fast with the actionable message. (#56)
            throw Things3Error.notAuthorized
        } catch {
            debugLog("[Things3] AppleScript failed (attempt 1): \(error.localizedDescription)")

            // Retry with an explicit launch + short delay in case Things wasn't ready
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s async sleep
            let retrySource = source.replacingOccurrences(
                of: "tell application id \"com.culturedcode.ThingsMac\"",
                with: "tell application id \"com.culturedcode.ThingsMac\"\n                launch\n                delay 0.3"
            )
            debugLog("[Things3] Retrying AppleScript with launch preamble...")

            do {
                let result = try await executeAppleScript(retrySource, timeout: timeout)
                debugLog("[Things3] AppleScript succeeded on retry")
                return result
            } catch {
                debugLog("[Things3] AppleScript failed (attempt 2): \(error.localizedDescription)")
                throw error
            }
        }
    }

    /// Send an update to Things 3 via URL scheme (locale-independent).
    private func updateTaskViaURLScheme(params: [String: String]) throws {
        var components = URLComponents()
        components.scheme = "things"
        components.host = ""
        components.path = "/update"
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else { return }
        let success = NSWorkspace.shared.open(url)
        if !success {
            debugLog("[Things3] URL scheme update failed for task \(params["id"] ?? "?")")
        }
    }

    /// Execute AppleScript with a timeout to prevent sync from blocking indefinitely.
    private func executeAppleScript(_ source: String, timeout: TimeInterval = 30) async throws -> NSAppleEventDescriptor? {
        try await withThrowingTaskGroup(of: NSAppleEventDescriptor?.self) { group in
            group.addTask {
                let script = NSAppleScript(source: source)
                var error: NSDictionary?
                let result = script?.executeAndReturnError(&error)
                if let error = error {
                    let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                    let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown"
                    throw Things3Error.classifyAppleScriptError(errorNumber: number, message: message)
                }
                return result
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Things3Error.appleScriptTimeout
            }
            guard let result = try await group.next() else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return result
        }
    }

    /// Fetch recently completed tasks from the Things 3 Logbook.
    /// Uses AppleScript date comparison to limit results to `withinDays` days,
    /// avoiding the performance hit of fetching thousands of old completed tasks.
    private func fetchRecentLogbookTasks(withinDays days: Int) async throws -> [SyncTask] {
        // AppleScript: iterate Logbook tasks, skip those completed more than N days ago.
        // Things 3 Logbook is sorted by completion date (newest first), so we stop
        // early once we hit a task older than the cutoff. Capped at 500 items max.
        let source = """
            tell application id "com.culturedcode.ThingsMac"
                set cutoff to (current date) - \(days) * days
                set todoList to {}
                set itemCount to 0
                repeat with toDo in to dos of list "Logbook"
                    set itemCount to itemCount + 1
                    if itemCount > 500 then exit repeat
                    set todoCompletionDate to ""
                    try
                        set todoCompletionDate to completion date of toDo
                    end try
                    if todoCompletionDate is "" then
                        -- Skip tasks with no completion date to avoid infinite loop
                    else
                        if todoCompletionDate < cutoff then exit repeat
                        set todoId to id of toDo
                        set todoName to name of toDo
                        set todoNotes to notes of toDo
                        set todoStatus to status of toDo
                        set todoDueDate to ""
                        try
                            set todoDueDate to due date of toDo as string
                        end try
                        set todoCompletionDateStr to completion date of toDo as string
                        set todoTagNames to tag names of toDo
                        set todoProject to ""
                        try
                            set todoProject to name of project of toDo
                        end try
                        set todoArea to ""
                        try
                            set todoArea to name of area of toDo
                        end try
                        set todoData to todoId & "|||" & todoName & "|||" & todoNotes & "|||" & (todoStatus as string) & "|||" & todoDueDate & "|||" & todoCompletionDateStr & "|||" & todoTagNames & "|||" & todoProject & "|||" & todoArea
                        set end of todoList to todoData
                    end if
                end repeat
                set AppleScript's text item delimiters to "~~~"
                return todoList as string
            end tell
        """

        guard let result = try await executeAppleScript(source, timeout: 30),
              let resultString = result.stringValue else {
            debugLog("[Things3] AppleScript returned nil fetching Logbook")
            return []
        }

        guard !resultString.isEmpty else { return [] }

        var tasks: [SyncTask] = []
        let todoStrings = resultString.components(separatedBy: "~~~")

        for todoStr in todoStrings {
            let parts = todoStr.components(separatedBy: "|||")
            guard parts.count >= 4 else { continue }

            let id = parts[0]
            let name = parts[1]
            let notes = parts.count > 2 ? parts[2] : ""
            let statusStr = parts.count > 3 ? parts[3] : ""
            let dueDateStr = parts.count > 4 ? parts[4] : ""
            let completionDateStr = parts.count > 5 ? parts[5] : ""
            let tagNames = parts.count > 6 ? parts[6] : ""
            let project = parts.count > 7 ? parts[7] : ""
            let area = parts.count > 8 ? parts[8] : ""

            let isCompleted = statusStr.contains("completed")
            let dueDate = parseAppleScriptDate(dueDateStr)
            let completionDate = parseAppleScriptDate(completionDateStr)

            let tags = tagNames.isEmpty ? [] : tagNames.components(separatedBy: ", ").map { "#\($0)" }
            let targetList = !project.isEmpty ? project : (!area.isEmpty ? area : "Logbook")

            let task = SyncTask(
                title: name,
                isCompleted: isCompleted,
                priority: .none,
                dueDate: dueDate,
                completedDate: completionDate,
                tags: tags,
                targetList: targetList,
                notes: notes.isEmpty ? nil : notes,
                remindersId: id,
                lastModified: completionDate ?? Date()
            )
            tasks.append(task)
        }

        return tasks
    }

    /// Fetch tasks from a specific Things 3 list via AppleScript (with 30s timeout).
    private func fetchTasksFromList(_ listName: String) async throws -> [SyncTask] {
        let scriptSource = """
            tell application id "com.culturedcode.ThingsMac"
                set todoList to {}
                repeat with toDo in to dos of list "\(listName)"
                    set todoId to id of toDo
                    set todoName to name of toDo
                    set todoNotes to notes of toDo
                    set todoStatus to status of toDo
                    set todoDueDate to ""
                    try
                        set todoDueDate to due date of toDo as string
                    end try
                    set todoCompletionDate to ""
                    try
                        set todoCompletionDate to completion date of toDo as string
                    end try
                    set todoTagNames to tag names of toDo
                    set todoProject to ""
                    try
                        set todoProject to name of project of toDo
                    end try
                    set todoArea to ""
                    try
                        set todoArea to name of area of toDo
                    end try

                    set todoData to todoId & "|||" & todoName & "|||" & todoNotes & "|||" & (todoStatus as string) & "|||" & todoDueDate & "|||" & todoCompletionDate & "|||" & todoTagNames & "|||" & todoProject & "|||" & todoArea
                    set end of todoList to todoData
                end repeat
                set AppleScript's text item delimiters to "~~~"
                return todoList as string
            end tell
        """

        guard let result = try await executeAppleScript(scriptSource, timeout: 30),
              let resultString = result.stringValue else {
            debugLog("[Things3] AppleScript returned nil fetching \(listName)")
            return []
        }

        guard !resultString.isEmpty else { return [] }

        var tasks: [SyncTask] = []
        let todoStrings = resultString.components(separatedBy: "~~~")

        for todoStr in todoStrings {
            let parts = todoStr.components(separatedBy: "|||")
            guard parts.count >= 4 else { continue }

            let id = parts[0]
            let name = parts[1]
            let notes = parts.count > 2 ? parts[2] : ""
            let statusStr = parts.count > 3 ? parts[3] : ""
            let dueDateStr = parts.count > 4 ? parts[4] : ""
            let completionDateStr = parts.count > 5 ? parts[5] : ""
            let tagNames = parts.count > 6 ? parts[6] : ""
            let project = parts.count > 7 ? parts[7] : ""
            let area = parts.count > 8 ? parts[8] : ""

            let isCompleted = statusStr.contains("completed")
            let dueDate = parseAppleScriptDate(dueDateStr)
            let completionDate = parseAppleScriptDate(completionDateStr)

            let tags = tagNames.isEmpty ? [] : tagNames.components(separatedBy: ", ").map { "#\($0)" }
            let targetList = !project.isEmpty ? project : (!area.isEmpty ? area : listName)

            let task = SyncTask(
                title: name,
                isCompleted: isCompleted,
                priority: .none, // Things 3 doesn't expose priority via AppleScript
                dueDate: dueDate,
                completedDate: completionDate,
                tags: tags,
                targetList: targetList,
                notes: notes.isEmpty ? nil : notes,
                remindersId: id,
                lastModified: completionDate ?? Date()
            )
            tasks.append(task)
        }

        return tasks
    }

    private func isThings3Installed() -> Bool {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.culturedcode.ThingsMac") != nil
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Format date for AppleScript date literal.
    private func formatAppleScriptDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: date)
    }

    private func parseAppleScriptDate(_ dateStr: String) -> Date? {
        guard !dateStr.isEmpty else { return nil }
        // AppleScript dates come in locale-dependent format
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        if let date = formatter.date(from: dateStr) { return date }

        // Try ISO format
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        return isoFormatter.date(from: dateStr)
    }
}

// MARK: - Errors

enum Things3Error: LocalizedError, Equatable {
    case notInstalled
    case appleScriptAccessDenied
    case notAuthorized          // macOS Automation permission not granted (AppleEvent -1743/-1744)
    case appleScriptError(String)
    case appleScriptTimeout
    case authTokenRequired
    case invalidURL
    case taskNotFound(String)
    case urlSchemeNotHandled
    case listFetchFailed(listName: String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Things 3 is not installed. Please install Things 3 from the Mac App Store."
        case .appleScriptAccessDenied:
            return "Cannot access Things 3 via AppleScript. Please grant access in System Settings > Privacy & Security > Automation."
        case .notAuthorized:
            return "Remindian isn't allowed to control Things 3. Open System Settings → Privacy & Security → Automation, find Remindian, and turn ON the Things3 switch. If Remindian or Things3 isn't listed, run `tccutil reset AppleEvents com.remindian.app` in Terminal and start a sync again to re-trigger the permission prompt."
        case .appleScriptError(let message):
            return "Things 3 AppleScript error: \(message)"
        case .appleScriptTimeout:
            return "Things 3 AppleScript timed out. Things 3 may be unresponsive, or have too many tasks. Try restarting Things 3."
        case .authTokenRequired:
            return "Things 3 auth token required for updates. Go to Things > Settings > General > Enable Things URLs to get your token."
        case .invalidURL:
            return "Failed to build Things URL"
        case .taskNotFound(let title):
            return "Could not find Things task: \(title)"
        case .urlSchemeNotHandled:
            return "Things 3 URL scheme failed. Make sure Things 3 is installed and the things:// URL scheme is registered."
        case .listFetchFailed(let listName, let underlying):
            return "Skipped Things 3 list '\(listName)' — sync continued with other lists. (\(underlying))"
        }
    }

    /// Classify a raw NSAppleScript error into a typed Things3Error.
    ///
    /// `errorNumber` is the value under `NSAppleScript.errorNumber`. The key
    /// codes (from `MacErrors.h` / AppleEvents):
    ///   -1743  errAEEventNotPermitted    — user denied Automation permission
    ///   -1744  errAEEventWouldRequireUserConsent — consent not yet given
    ///   -600   procNotFound               — target app isn't running (transient)
    ///   -609   connectionInvalid          — app connection dropped (transient)
    ///
    /// Permission errors (-1743/-1744) map to `.notAuthorized` so callers can
    /// (a) show the actionable Automation-permission message and (b) skip the
    /// pointless retry that made a denied sync feel "stuck" (#56). Everything
    /// else stays a generic `.appleScriptError` carrying the original message.
    static func classifyAppleScriptError(errorNumber: Int, message: String) -> Things3Error {
        switch errorNumber {
        case -1743, -1744:
            return .notAuthorized
        default:
            return .appleScriptError(message)
        }
    }
}
