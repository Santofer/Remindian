import Foundation

/// Asana destination using the REST API v1.
///
/// Architecture:
/// - AUTH: Personal Access Token (Bearer token in Authorization header)
/// - READ: GET /tasks (in workspace), GET /projects (list projects)
/// - CREATE: POST /tasks
/// - UPDATE: PUT /tasks/{gid}
/// - COMPLETE: PUT /tasks/{gid} with completed: true
/// - DELETE: DELETE /tasks/{gid}
///
/// API docs: https://developers.asana.com/reference
class AsanaDestination: TaskDestination {
    let destinationName = "Asana"

    var apiToken: String = ""

    private let baseURL = "https://app.asana.com/api/1.0"
    private let session = URLSession.shared

    // Cache
    private var cachedWorkspaceGid: String?
    private var cachedProjects: [AsanaProject] = []
    private var lastProjectRefresh: Date?

    // MARK: - Authorization

    func requestAccess() async throws -> Bool {
        guard !apiToken.isEmpty else {
            throw AsanaError.invalidToken
        }
        // Verify token by fetching workspaces
        let (data, response) = try await makeRequest(method: "GET", path: "/workspaces")
        guard response.statusCode == 200 else { return false }
        let wrapper = try JSONDecoder().decode(AsanaDataWrapper<[AsanaWorkspace]>.self, from: data)
        if let first = wrapper.data.first {
            cachedWorkspaceGid = first.gid
        }
        return !wrapper.data.isEmpty
    }

    // MARK: - Fetching

    func fetchAllTasks() async throws -> [SyncTask] {
        guard let workspaceGid = try await getWorkspaceGid() else {
            throw AsanaError.noWorkspace
        }

        let projects = try await fetchProjects(workspaceGid: workspaceGid)
        // API gids are unique today, but never trap on a duplicate from a malformed
        // response — merge instead of `uniqueKeysWithValues:` (#80 crash class).
        let projectMap = Dictionary(projects.map { ($0.gid, $0.name) }, uniquingKeysWith: { _, latest in latest })

        var allTasks: [SyncTask] = []
        var offset: String? = nil

        // Fetch tasks assigned to me in the workspace
        repeat {
            var path = "/tasks?workspace=\(workspaceGid)&assignee=me&opt_fields=name,completed,due_on,start_on,notes,memberships.project.gid,memberships.project.name&limit=100"
            if let offset = offset {
                path += "&offset=\(offset)"
            }
            let (data, _) = try await makeRequest(method: "GET", path: path)
            let page = try JSONDecoder().decode(AsanaPagedResponse<AsanaTask>.self, from: data)
            for task in page.data {
                allTasks.append(mapToSyncTask(task, projectMap: projectMap))
            }
            offset = page.nextPage?.offset
        } while offset != nil

        debugLog("[Asana] Fetched \(allTasks.count) tasks across \(projectMap.count) projects")
        return allTasks
    }

    func getAvailableLists() async -> [String] {
        if let lastRefresh = lastProjectRefresh, Date().timeIntervalSince(lastRefresh) < 60 {
            return cachedProjects.map { $0.name }
        }
        do {
            guard let workspaceGid = try await getWorkspaceGid() else { return [] }
            let projects = try await fetchProjects(workspaceGid: workspaceGid)
            cachedProjects = projects
            lastProjectRefresh = Date()
            return projects.map { $0.name }
        } catch {
            debugLog("[Asana] Failed to fetch projects: \(error)")
            return cachedProjects.map { $0.name }
        }
    }

    // MARK: - CRUD

    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        guard let workspaceGid = try await getWorkspaceGid() else {
            throw AsanaError.noWorkspace
        }

        var body: [String: Any] = [
            "name": task.title,
            "workspace": workspaceGid
        ]

        if task.isCompleted {
            body["completed"] = true
        }

        if let dueDate = task.dueDate {
            body["due_on"] = formatDate(dueDate)
        }

        if let startDate = task.startDate {
            body["start_on"] = formatDate(startDate)
        }

        if let notes = task.notes, !notes.isEmpty {
            body["notes"] = notes
        }

        // Assign to project
        if let projectGid = try await resolveProjectGid(for: listName, workspaceGid: workspaceGid) {
            body["projects"] = [projectGid]
        }

        let jsonData = try JSONSerialization.data(withJSONObject: ["data": body])
        let (data, _) = try await makeRequest(method: "POST", path: "/tasks", body: jsonData)
        let wrapper = try JSONDecoder().decode(AsanaDataWrapper<AsanaTask>.self, from: data)

        debugLog("[Asana] Created task \"\(task.title)\" with gid=\(wrapper.data.gid)")
        return wrapper.data.gid
    }

    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        var body: [String: Any] = [
            "name": task.title,
            "completed": task.isCompleted
        ]

        if let dueDate = task.dueDate {
            body["due_on"] = formatDate(dueDate)
        } else {
            body["due_on"] = NSNull()
        }

        if let startDate = task.startDate {
            body["start_on"] = formatDate(startDate)
        } else {
            body["start_on"] = NSNull()
        }

        if let notes = task.notes {
            body["notes"] = notes
        }

        let jsonData = try JSONSerialization.data(withJSONObject: ["data": body])
        try await makeRequest(method: "PUT", path: "/tasks/\(id)", body: jsonData)
    }

    func moveTask(withId id: String, toList listName: String) async throws {
        guard let workspaceGid = try await getWorkspaceGid() else {
            throw AsanaError.noWorkspace
        }
        guard let projectGid = try await resolveProjectGid(for: listName, workspaceGid: workspaceGid) else {
            throw AsanaError.projectNotFound(listName)
        }

        // Add to new project
        let body: [String: Any] = ["data": ["project": projectGid]]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        try await makeRequest(method: "POST", path: "/tasks/\(id)/addProject", body: jsonData)
    }

    func deleteTask(withId id: String) async throws {
        try await makeRequest(method: "DELETE", path: "/tasks/\(id)")
    }

    func refresh() {
        cachedProjects = []
        cachedWorkspaceGid = nil
        lastProjectRefresh = nil
    }

    // MARK: - Private Helpers

    private func getWorkspaceGid() async throws -> String? {
        if let gid = cachedWorkspaceGid { return gid }
        let (data, _) = try await makeRequest(method: "GET", path: "/workspaces")
        let wrapper = try JSONDecoder().decode(AsanaDataWrapper<[AsanaWorkspace]>.self, from: data)
        cachedWorkspaceGid = wrapper.data.first?.gid
        return cachedWorkspaceGid
    }

    private func fetchProjects(workspaceGid: String) async throws -> [AsanaProject] {
        var allProjects: [AsanaProject] = []
        var offset: String? = nil

        repeat {
            var path = "/projects?workspace=\(workspaceGid)&opt_fields=name&limit=100"
            if let offset = offset {
                path += "&offset=\(offset)"
            }
            let (data, _) = try await makeRequest(method: "GET", path: path)
            let page = try JSONDecoder().decode(AsanaPagedResponse<AsanaProject>.self, from: data)
            allProjects.append(contentsOf: page.data)
            offset = page.nextPage?.offset
        } while offset != nil

        return allProjects
    }

    private func resolveProjectGid(for listName: String, workspaceGid: String) async throws -> String? {
        let projects = try await fetchProjects(workspaceGid: workspaceGid)
        return projects.first(where: { $0.name.lowercased() == listName.lowercased() })?.gid
    }

    @discardableResult
    private func makeRequest(method: String, path: String, body: Data? = nil, retryCount: Int = 0) async throws -> (Data, HTTPURLResponse) {
        let cleanToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanToken.isEmpty else {
            throw AsanaError.invalidToken
        }

        guard let url = URL(string: baseURL + path) else {
            throw AsanaError.apiError(0, "Invalid URL: \(baseURL + path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(cleanToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        debugLog("[Asana] \(method) \(url.absoluteString)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AsanaError.apiError(0, "Invalid response")
        }

        debugLog("[Asana] \(method) \(path) -> HTTP \(httpResponse.statusCode)")

        switch httpResponse.statusCode {
        case 200...299:
            return (data, httpResponse)
        case 401, 403:
            throw AsanaError.invalidToken
        case 429:
            if retryCount < 2 {
                let retryAfter = Double(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5
                debugLog("[Asana] Rate limited, retrying after \(retryAfter)s")
                try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                return try await makeRequest(method: method, path: path, body: body, retryCount: retryCount + 1)
            }
            throw AsanaError.rateLimited
        case 500...599:
            if retryCount < 1 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return try await makeRequest(method: method, path: path, body: body, retryCount: retryCount + 1)
            }
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw AsanaError.serverError(httpResponse.statusCode, snippet)
        default:
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw AsanaError.apiError(httpResponse.statusCode, snippet)
        }
    }

    // MARK: - Mapping

    private func mapToSyncTask(_ task: AsanaTask, projectMap: [String: String]) -> SyncTask {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let dueDate = task.dueOn.flatMap { dateFormatter.date(from: $0) }
        let startDate = task.startOn.flatMap { dateFormatter.date(from: $0) }

        // Get project name from memberships
        let projectName = task.memberships?.first?.project?.name ?? ""

        return SyncTask(
            title: task.name,
            isCompleted: task.completed,
            dueDate: dueDate,
            startDate: startDate,
            targetList: projectName.isEmpty ? nil : projectName,
            notes: task.notes,
            remindersId: task.gid,
            lastModified: Date()
        )
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - API Models

private struct AsanaDataWrapper<T: Codable>: Codable {
    let data: T
}

private struct AsanaPagedResponse<T: Codable>: Codable {
    let data: [T]
    let nextPage: AsanaNextPage?

    enum CodingKeys: String, CodingKey {
        case data
        case nextPage = "next_page"
    }
}

private struct AsanaNextPage: Codable {
    let offset: String
}

private struct AsanaWorkspace: Codable {
    let gid: String
    let name: String
}

private struct AsanaProject: Codable {
    let gid: String
    let name: String
}

private struct AsanaTask: Codable {
    let gid: String
    let name: String
    let completed: Bool
    let dueOn: String?
    let startOn: String?
    let notes: String?
    let memberships: [AsanaMembership]?

    enum CodingKeys: String, CodingKey {
        case gid, name, completed, notes, memberships
        case dueOn = "due_on"
        case startOn = "start_on"
    }
}

private struct AsanaMembership: Codable {
    let project: AsanaMembershipProject?
}

private struct AsanaMembershipProject: Codable {
    let gid: String
    let name: String
}

// MARK: - Errors

enum AsanaError: LocalizedError {
    case invalidToken
    case noWorkspace
    case rateLimited
    case projectNotFound(String)
    case apiError(Int, String)
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Invalid Asana API token. Get your Personal Access Token from Asana > My Settings > Apps > Developer Apps."
        case .noWorkspace:
            return "No Asana workspace found. Make sure your account belongs to at least one workspace."
        case .rateLimited:
            return "Asana API rate limit exceeded. Please wait a moment and try again."
        case .projectNotFound(let name):
            return "Asana project not found: \(name)"
        case .apiError(let code, let message):
            return "Asana API error (HTTP \(code)): \(message)"
        case .serverError(let code, let message):
            return "Asana server error (HTTP \(code)). Try again in a moment. \(message)"
        }
    }
}
