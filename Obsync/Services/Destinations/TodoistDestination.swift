import Foundation

/// Todoist destination using the API v1.
///
/// Architecture:
/// - AUTH: Personal API token (Bearer token in Authorization header)
/// - READ: GET /tasks (list all), GET /projects (list projects)
/// - CREATE: POST /tasks
/// - UPDATE: POST /tasks/{id}
/// - COMPLETE: POST /tasks/{id}/close
/// - DELETE: DELETE /tasks/{id}
///
/// API v1 returns paginated responses: { "results": [...], "next_cursor": "..." }
/// API docs: https://developer.todoist.com/api/v1/
class TodoistDestination: TaskDestination {
    let destinationName = "Todoist"

    var apiToken: String = ""

    private let baseURL = "https://api.todoist.com/api/v1"
    private let session = URLSession.shared

    // Cache
    private var cachedProjects: [TodoistProject] = []
    private var lastProjectRefresh: Date?

    // MARK: - Authorization

    func requestAccess() async throws -> Bool {
        guard !apiToken.isEmpty else {
            throw TodoistError.invalidToken
        }
        // Verify token by fetching projects (lighter than tasks)
        let (data, response) = try await makeRequest(method: "GET", path: "/projects")
        guard response.statusCode == 200 else { return false }
        // Verify we can decode the response
        let _ = try JSONDecoder().decode(TodoistPaginatedResponse<TodoistProject>.self, from: data)
        return true
    }

    // MARK: - Fetching

    func fetchAllTasks() async throws -> [SyncTask] {
        var allTasks: [TodoistTask] = []
        var cursor: String? = nil

        // Paginate through all tasks
        repeat {
            var path = "/tasks?limit=200"
            if let cursor = cursor {
                path += "&cursor=\(cursor)"
            }
            let (data, _) = try await makeRequest(method: "GET", path: path)
            let page: TodoistPaginatedResponse<TodoistTask>
            do {
                page = try JSONDecoder().decode(TodoistPaginatedResponse<TodoistTask>.self, from: data)
            } catch {
                let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
                debugLog("[Todoist] JSON decode error: \(error). Response: \(snippet)")
                throw error
            }
            allTasks.append(contentsOf: page.results)
            cursor = page.nextCursor
        } while cursor != nil

        let projects = try await fetchProjects()
        // API ids are unique today, but never trap on a duplicate from a malformed
        // response — merge instead of `uniqueKeysWithValues:` (#80 crash class).
        let projectMap = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { _, latest in latest })

        debugLog("[Todoist] Fetched \(allTasks.count) tasks across \(projectMap.count) projects")
        return allTasks.map { task in
            mapToSyncTask(task, projectMap: projectMap)
        }
    }

    func getAvailableLists() async -> [String] {
        if let lastRefresh = lastProjectRefresh, Date().timeIntervalSince(lastRefresh) < 60 {
            return cachedProjects.map { $0.name }
        }
        do {
            let projects = try await fetchProjects()
            cachedProjects = projects
            lastProjectRefresh = Date()
            return projects.map { $0.name }
        } catch {
            debugLog("[Todoist] Failed to fetch projects: \(error)")
            return cachedProjects.map { $0.name }
        }
    }

    // MARK: - CRUD

    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        let projectId = try await resolveProjectId(for: listName)

        var body: [String: Any] = [
            "content": task.title,
            "priority": mapPriorityToTodoist(task.priority)
        ]

        if let projectId = projectId {
            body["project_id"] = projectId
        }

        if let dueDate = task.dueDate {
            if config.includeDueTime {
                body["due_datetime"] = ISO8601DateFormatter().string(from: dueDate)
            } else {
                body["due_date"] = formatDate(dueDate)
            }
        }

        if let notes = task.notes, !notes.isEmpty {
            body["description"] = notes
        }

        let labels = task.tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        if !labels.isEmpty {
            body["labels"] = labels
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await makeRequest(method: "POST", path: "/tasks", body: jsonData)
        let created = try JSONDecoder().decode(TodoistTask.self, from: data)

        if task.isCompleted {
            try await closeTask(id: created.id)
        }

        debugLog("[Todoist] Created task \"\(task.title)\" with id=\(created.id)")
        return created.id
    }

    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        var body: [String: Any] = [
            "content": task.title,
            "priority": mapPriorityToTodoist(task.priority)
        ]

        if let dueDate = task.dueDate {
            if config.includeDueTime {
                body["due_datetime"] = ISO8601DateFormatter().string(from: dueDate)
            } else {
                body["due_date"] = formatDate(dueDate)
            }
        } else {
            body["due_string"] = NSNull()
        }

        if let notes = task.notes {
            body["description"] = notes
        }

        let labels = task.tags.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        body["labels"] = labels

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        try await makeRequest(method: "POST", path: "/tasks/\(id)", body: jsonData)

        if task.isCompleted {
            try await closeTask(id: id)
        }
    }

    func moveTask(withId id: String, toList listName: String) async throws {
        guard let projectId = try await resolveProjectId(for: listName) else {
            throw TodoistError.projectNotFound(listName)
        }

        let body: [String: Any] = ["project_id": projectId]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        try await makeRequest(method: "POST", path: "/tasks/\(id)/move", body: jsonData)
    }

    func deleteTask(withId id: String) async throws {
        try await makeRequest(method: "DELETE", path: "/tasks/\(id)")
    }

    func refresh() {
        cachedProjects = []
        lastProjectRefresh = nil
    }

    // MARK: - Private Helpers

    private func closeTask(id: String) async throws {
        try await makeRequest(method: "POST", path: "/tasks/\(id)/close")
    }

    private func fetchProjects() async throws -> [TodoistProject] {
        let (data, _) = try await makeRequest(method: "GET", path: "/projects")
        do {
            let page = try JSONDecoder().decode(TodoistPaginatedResponse<TodoistProject>.self, from: data)
            return page.results
        } catch {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            debugLog("[Todoist] Projects decode error: \(error). Response: \(snippet)")
            throw error
        }
    }

    private func resolveProjectId(for listName: String) async throws -> String? {
        let projects = try await fetchProjects()
        return projects.first(where: { $0.name.lowercased() == listName.lowercased() })?.id
    }

    @discardableResult
    private func makeRequest(method: String, path: String, body: Data? = nil, retryCount: Int = 0) async throws -> (Data, HTTPURLResponse) {
        let cleanToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            throw TodoistError.invalidToken
        }

        guard let url = URL(string: baseURL + path) else {
            throw TodoistError.apiError(0, "Invalid URL: \(baseURL + path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        debugLog("[Todoist] \(method) \(url.absoluteString)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TodoistError.apiError(0, "Invalid response")
        }

        debugLog("[Todoist] \(method) \(path) → HTTP \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 204:
            return (Data(), httpResponse)
        case 200...299:
            return (data, httpResponse)
        case 401, 403:
            throw TodoistError.invalidToken
        case 429:
            if retryCount < 2 {
                let retryAfter = Double(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5
                debugLog("[Todoist] Rate limited, retrying after \(retryAfter)s")
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                return try await makeRequest(method: method, path: path, body: body, retryCount: retryCount + 1)
            }
            throw TodoistError.rateLimited
        case 500...599:
            if retryCount < 1 {
                debugLog("[Todoist] Server error \(httpResponse.statusCode), retrying in 2s...")
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await makeRequest(method: method, path: path, body: body, retryCount: retryCount + 1)
            }
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw TodoistError.serverError(httpResponse.statusCode, snippet)
        default:
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw TodoistError.apiError(httpResponse.statusCode, snippet)
        }
    }

    // MARK: - Mapping

    private func mapToSyncTask(_ task: TodoistTask, projectMap: [String: String]) -> SyncTask {
        let priority = mapPriorityFromTodoist(task.priority)
        let tags = task.labels.map { "#\($0)" }
        let dueDate = parseDueDate(task.due)
        let projectName = projectMap[task.projectId] ?? ""

        return SyncTask(
            title: task.content,
            isCompleted: task.checked,
            priority: priority,
            dueDate: dueDate,
            tags: tags,
            targetList: projectName.isEmpty ? nil : projectName,
            notes: task.description.isEmpty ? nil : task.description,
            remindersId: task.id,
            lastModified: Date()
        )
    }

    private func mapPriorityToTodoist(_ priority: SyncTask.Priority) -> Int {
        switch priority {
        case .high: return 4
        case .medium: return 3
        case .low: return 2
        case .none: return 1
        }
    }

    private func mapPriorityFromTodoist(_ priority: Int) -> SyncTask.Priority {
        switch priority {
        case 4: return .high
        case 3: return .medium
        case 2: return .low
        default: return .none
        }
    }

    private func parseDueDate(_ due: TodoistDue?) -> Date? {
        guard let due = due else { return nil }
        if let datetime = due.datetime {
            return ISO8601DateFormatter().date(from: datetime)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: due.date)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - API Models

/// Generic paginated response wrapper for API v1
private struct TodoistPaginatedResponse<T: Codable>: Codable {
    let results: [T]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case nextCursor = "next_cursor"
    }
}

private struct TodoistTask: Codable {
    let id: String
    let content: String
    let description: String
    let priority: Int
    let labels: [String]
    let due: TodoistDue?
    let projectId: String
    let checked: Bool

    enum CodingKeys: String, CodingKey {
        case id, content, description, priority, labels, due, checked
        case projectId = "project_id"
    }
}

private struct TodoistProject: Codable {
    let id: String
    let name: String
}

private struct TodoistDue: Codable {
    let date: String
    let datetime: String?
    let string: String?
    let timezone: String?
    let lang: String?
    let isRecurring: Bool?

    enum CodingKeys: String, CodingKey {
        case date, datetime, string, timezone, lang
        case isRecurring = "is_recurring"
    }
}

// MARK: - Errors

enum TodoistError: LocalizedError {
    case invalidToken
    case rateLimited
    case apiError(Int, String)
    case serverError(Int, String)
    case projectNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Invalid Todoist API token. Get your token from Todoist > Settings > Integrations > Developer."
        case .rateLimited:
            return "Todoist API rate limit exceeded. Please wait a moment and try again."
        case .apiError(let code, let message):
            return "Todoist API error (HTTP \(code)): \(message)"
        case .serverError(let code, let message):
            return "Todoist server error (HTTP \(code)). This is usually temporary — try again in a moment. \(message)"
        case .projectNotFound(let name):
            return "Todoist project not found: \(name)"
        }
    }
}
