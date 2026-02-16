import Foundation
import AppKit

/// Things 3 destination using AppleScript (read) + URL scheme (write).
///
/// Architecture:
/// - READ: AppleScript via NSAppleScript for task properties (id, name, notes, due date, status, tags, project, area)
/// - CREATE: things:// URL scheme with JSON command via ThingsJSONCoder-style encoding
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

    // Cache for performance
    private var cachedLists: [String] = []
    private var lastListRefresh: Date?

    // MARK: - Authorization

    func requestAccess() async throws -> Bool {
        // Things 3 doesn't require explicit permission — we just need to check if it's installed
        guard isThings3Installed() else {
            throw Things3Error.notInstalled
        }

        // Test AppleScript access
        let testScript = NSAppleScript(source: """
            tell application "Things3"
                return name of application "Things3"
            end tell
        """)
        var error: NSDictionary?
        let result = testScript?.executeAndReturnError(&error)

        if error != nil {
            throw Things3Error.appleScriptAccessDenied
        }

        return result != nil
    }

    // MARK: - Fetching

    func fetchAllTasks() async throws -> [SyncTask] {
        var tasks: [SyncTask] = []

        // Fetch from Today, Inbox, Anytime, Upcoming, Someday
        let lists = ["Today", "Inbox", "Anytime", "Upcoming", "Someday"]
        for listName in lists {
            let listTasks = try fetchTasksFromList(listName)
            tasks.append(contentsOf: listTasks)
        }

        return tasks
    }

    func getAvailableLists() -> [String] {
        // Refresh cache every 60 seconds
        if let lastRefresh = lastListRefresh, Date().timeIntervalSince(lastRefresh) < 60 {
            return cachedLists
        }

        var lists = ["Inbox", "Today", "Anytime", "Upcoming", "Someday"]

        // Fetch projects and areas via AppleScript
        let script = NSAppleScript(source: """
            tell application "Things3"
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
        """)

        var error: NSDictionary?
        if let result = script?.executeAndReturnError(&error) {
            // Parse the AppleScript result
            if result.numberOfItems >= 2 {
                // Projects
                if let projects = result.atIndex(1) {
                    for i in 1...max(1, projects.numberOfItems) {
                        if let name = projects.atIndex(i)?.stringValue {
                            lists.append("📁 \(name)")
                        }
                    }
                }
                // Areas
                if let areas = result.atIndex(2) {
                    for i in 1...max(1, areas.numberOfItems) {
                        if let name = areas.atIndex(i)?.stringValue {
                            lists.append("📂 \(name)")
                        }
                    }
                }
            }
        }

        cachedLists = lists
        lastListRefresh = Date()
        return lists
    }

    // MARK: - CRUD

    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) throws -> String {
        // Build the things:// URL for creating a task
        var params: [String: String] = [
            "title": task.title,
            "show-quick-entry": "false"
        ]

        if let dueDate = task.dueDate {
            params["deadline"] = formatDate(dueDate)
        }

        if let startDate = task.startDate {
            params["when"] = formatDate(startDate)
        }

        if let notes = task.notes {
            params["notes"] = notes
        }

        // Map tags
        if !task.tags.isEmpty {
            let tagNames = task.tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            params["tags"] = tagNames.joined(separator: ",")
        }

        // Map list to project or area
        let cleanList = listName
            .replacingOccurrences(of: "📁 ", with: "")
            .replacingOccurrences(of: "📂 ", with: "")
        if listName.hasPrefix("📁 ") {
            params["list"] = cleanList
        }

        if task.isCompleted {
            params["completed"] = "true"
        }

        // Use x-callback-url to get the created task's ID
        let callbackId = UUID().uuidString
        params["x-success"] = "remindian://things-callback?id=\(callbackId)"

        // Build URL
        var components = URLComponents()
        components.scheme = "things"
        components.host = ""
        components.path = "/add"
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw Things3Error.invalidURL
        }

        // Open URL to create the task
        NSWorkspace.shared.open(url)

        // Since x-callback-url is async and we can't easily wait for it in this context,
        // we'll use AppleScript to find the just-created task by title
        // Wait briefly for Things to process
        Thread.sleep(forTimeInterval: 0.5)

        // Find the task ID via AppleScript
        let taskId = try findTaskIdByTitle(task.title)
        return taskId
    }

    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) throws {
        guard !authToken.isEmpty else {
            throw Things3Error.authTokenRequired
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

        if let notes = task.notes {
            params["notes"] = notes
        }

        var components = URLComponents()
        components.scheme = "things"
        components.host = ""
        components.path = "/update"
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw Things3Error.invalidURL
        }

        NSWorkspace.shared.open(url)
    }

    func moveTask(withId id: String, toList listName: String) throws {
        guard !authToken.isEmpty else {
            throw Things3Error.authTokenRequired
        }

        let cleanList = listName
            .replacingOccurrences(of: "📁 ", with: "")
            .replacingOccurrences(of: "📂 ", with: "")

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

        NSWorkspace.shared.open(url)
    }

    func deleteTask(withId id: String) throws {
        // Things 3 URL scheme doesn't support deletion.
        // Use AppleScript to move to Trash instead.
        let script = NSAppleScript(source: """
            tell application "Things3"
                set theTodo to to do id "\(id)"
                delete theTodo
            end tell
        """)

        var error: NSDictionary?
        script?.executeAndReturnError(&error)

        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            throw Things3Error.appleScriptError(message)
        }
    }

    func refresh() {
        cachedLists = []
        lastListRefresh = nil
    }

    // MARK: - AppleScript Helpers

    /// Fetch tasks from a specific Things 3 list via AppleScript.
    private func fetchTasksFromList(_ listName: String) throws -> [SyncTask] {
        let script = NSAppleScript(source: """
            tell application "Things3"
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
        """)

        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error),
              let resultString = result.stringValue else {
            if let error = error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                debugLog("[Things3] AppleScript error fetching \(listName): \(message)")
            }
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

    /// Find a task's Things ID by its title (used after creating via URL scheme).
    private func findTaskIdByTitle(_ title: String) throws -> String {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: """
            tell application "Things3"
                repeat with toDo in to dos of list "Inbox"
                    if name of toDo is "\(escapedTitle)" then
                        return id of toDo
                    end if
                end repeat
                repeat with toDo in to dos of list "Today"
                    if name of toDo is "\(escapedTitle)" then
                        return id of toDo
                    end if
                end repeat
                return "not-found"
            end tell
        """)

        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error),
              let taskId = result.stringValue,
              taskId != "not-found" else {
            throw Things3Error.taskNotFound(title)
        }

        return taskId
    }

    private func isThings3Installed() -> Bool {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.culturedcode.ThingsMac") != nil
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
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

enum Things3Error: LocalizedError {
    case notInstalled
    case appleScriptAccessDenied
    case appleScriptError(String)
    case authTokenRequired
    case invalidURL
    case taskNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Things 3 is not installed. Please install Things 3 from the Mac App Store."
        case .appleScriptAccessDenied:
            return "Cannot access Things 3 via AppleScript. Please grant access in System Settings > Privacy & Security > Automation."
        case .appleScriptError(let message):
            return "Things 3 AppleScript error: \(message)"
        case .authTokenRequired:
            return "Things 3 auth token required for updates. Go to Things > Settings > General > Enable Things URLs to get your token."
        case .invalidURL:
            return "Failed to build Things URL"
        case .taskNotFound(let title):
            return "Could not find Things task: \(title)"
        }
    }
}
