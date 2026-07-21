import Foundation
import AppKit

/// TickTick destination using the Open API v1.
///
/// Architecture:
/// - AUTH: OAuth 2.0 (Authorization Code flow via remindian:// URL scheme callback)
/// - READ: GET /project (list projects) + GET /project/{id}/data (tasks per project)
/// - CREATE: POST /task
/// - UPDATE: POST /task/{id}
/// - COMPLETE: POST /project/{pid}/task/{tid}/complete
/// - DELETE: DELETE /project/{pid}/task/{tid}
///
/// Limitations:
/// - No global "list all tasks" endpoint — must iterate all projects
/// - No tag/label support in the Open API
/// - OAuth required (no simple API token)
///
/// API docs: https://developer.ticktick.com/
class TickTickDestination: TaskDestination {
    let destinationName = "TickTick"

    var accessToken: String = ""
    var refreshToken: String = ""
    var tokenExpiry: Date?

    private let baseURL = "https://api.ticktick.com/open/v1"
    private let session = URLSession.shared

    // TickTick OAuth credentials — registered at developer.ticktick.com
    static let clientId = "cVieUxm74J0zDt5RVt"
    static let clientSecret = "ypcLQCk6Zh2TtBK83UvNs1hXwnuS4Mqs"
    static let redirectURI = "http://127.0.0.1:23847/oauth/ticktick"
    static let callbackPort: UInt16 = 23847

    // Cache
    private var cachedProjects: [TickTickProject] = []
    private var lastProjectRefresh: Date?

    // MARK: - Authorization

    func requestAccess() async throws -> Bool {
        guard !accessToken.isEmpty else {
            throw TickTickError.notConnected
        }
        try await ensureValidToken()
        // Verify by fetching projects
        let (_, response) = try await makeRequest(method: "GET", path: "/project")
        return response.statusCode == 200
    }

    // MARK: - Fetching

    func fetchAllTasks() async throws -> [SyncTask] {
        try await ensureValidToken()
        let projects = try await fetchProjects()
        var allTasks: [SyncTask] = []

        for project in projects {
            let tasks = try await fetchTasksInProject(project)
            allTasks.append(contentsOf: tasks)
        }

        return allTasks
    }

    func getAvailableLists() async -> [String] {
        if let lastRefresh = lastProjectRefresh, Date().timeIntervalSince(lastRefresh) < 60 {
            return cachedProjects.map { $0.name }
        }
        do {
            try await ensureValidToken()
            let projects = try await fetchProjects()
            cachedProjects = projects
            lastProjectRefresh = Date()
            return projects.map { $0.name }
        } catch {
            debugLog("[TickTick] Failed to fetch projects: \(error)")
            return cachedProjects.map { $0.name }
        }
    }

    // MARK: - CRUD

    func createTask(from task: SyncTask, inList listName: String, config: SyncConfiguration) async throws -> String {
        try await ensureValidToken()
        let projectId = try await resolveProjectId(for: listName)

        var body: [String: Any] = [
            "title": task.title,
            "priority": mapPriorityToTickTick(task.priority)
        ]

        if let projectId = projectId {
            body["projectId"] = projectId
        }

        if let dueDate = task.dueDate {
            body["dueDate"] = ISO8601DateFormatter().string(from: dueDate)
            body["isAllDay"] = !config.includeDueTime
        }

        if let notes = task.notes, !notes.isEmpty {
            body["content"] = notes
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await makeRequest(method: "POST", path: "/task", body: jsonData)
        let created = try JSONDecoder().decode(TickTickTask.self, from: data)

        if task.isCompleted, let pid = created.projectId {
            try await completeTask(projectId: pid, taskId: created.id)
        }

        debugLog("[TickTick] Created task \"\(task.title)\" with id=\(created.id)")
        return created.id
    }

    func updateTask(withId id: String, from task: SyncTask, config: SyncConfiguration) async throws {
        try await ensureValidToken()

        var body: [String: Any] = [
            "title": task.title,
            "priority": mapPriorityToTickTick(task.priority)
        ]

        if let dueDate = task.dueDate {
            body["dueDate"] = ISO8601DateFormatter().string(from: dueDate)
            body["isAllDay"] = !config.includeDueTime
        }

        if let notes = task.notes {
            body["content"] = notes
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        try await makeRequest(method: "POST", path: "/task/\(id)", body: jsonData)
    }

    func moveTask(withId id: String, toList listName: String) async throws {
        // TickTick doesn't have a direct move endpoint in the Open API.
        // The task's projectId can be updated via the update endpoint.
        try await ensureValidToken()
        guard let projectId = try await resolveProjectId(for: listName) else {
            throw TickTickError.projectNotFound(listName)
        }

        let body: [String: Any] = ["projectId": projectId]
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        try await makeRequest(method: "POST", path: "/task/\(id)", body: jsonData)
    }

    func deleteTask(withId id: String) async throws {
        try await ensureValidToken()
        // TickTick delete is project-scoped. We need the projectId.
        // Try to find it from cached data, or use the task endpoint.
        let projects = try await fetchProjects()
        for project in projects {
            // Try deleting from each project — the API will succeed for the correct one
            do {
                try await makeRequest(method: "DELETE", path: "/project/\(project.id)/task/\(id)")
                return
            } catch {
                continue
            }
        }
        throw TickTickError.apiError(404, "Task \(id) not found in any project")
    }

    func refresh() {
        cachedProjects = []
        lastProjectRefresh = nil
    }

    // MARK: - OAuth

    /// Whether TickTick OAuth credentials are configured.
    static var isOAuthConfigured: Bool {
        !clientId.isEmpty && !clientSecret.isEmpty
    }

    /// Local HTTP server for OAuth callback
    private var callbackServer: TickTickOAuthServer?

    /// Initiate the OAuth flow by opening the browser and starting a local callback server.
    func startOAuthFlow() {
        guard Self.isOAuthConfigured else {
            debugLog("[TickTick] OAuth not configured — client credentials missing")
            NotificationCenter.default.post(
                name: NSNotification.Name("TickTickOAuthNotConfigured"),
                object: nil
            )
            return
        }

        // Start local HTTP server to receive the callback.
        // CRITICAL (#61): start() is now synchronous through bind+listen; we
        // MUST NOT open the browser until it returns successfully, otherwise
        // the OAuth redirect can race past the unbound port and the user
        // sees ERR_CONNECTION_REFUSED.
        // Bind this authorization request to a random state so a callback from a
        // different (attacker-initiated) flow can't be accepted (H3/L1).
        let oauthState = OAuthCallbackHandler.shared.beginTickTickFlow()

        callbackServer = TickTickOAuthServer(port: Self.callbackPort) { [weak self] code, state in
            guard let self = self else { return }
            guard OAuthCallbackHandler.shared.consumeTickTickState(state) else {
                debugLog("[TickTick] OAuth callback rejected: state mismatch")
                self.callbackServer = nil
                NotificationCenter.default.post(
                    name: NSNotification.Name("TickTickOAuthServerStartFailed"),
                    object: nil,
                    userInfo: ["message": "Sign-in could not be verified (state mismatch). Please try connecting again."]
                )
                return
            }
            debugLog("[TickTick] OAuth code received via localhost callback")
            DispatchQueue.main.async {
                OAuthCallbackHandler.shared.tickTickAuthCode = code
            }
            // Server stops itself after receiving the code
            self.callbackServer = nil
        }
        do {
            try callbackServer?.start()
        } catch {
            debugLog("[TickTick] Could not start OAuth callback server: \(error.localizedDescription)")
            callbackServer = nil
            // Notify the UI so the user gets a real error instead of a silent failure.
            NotificationCenter.default.post(
                name: NSNotification.Name("TickTickOAuthServerStartFailed"),
                object: nil,
                userInfo: ["message": error.localizedDescription]
            )
            return
        }

        let encodedRedirect = Self.redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.redirectURI
        let encodedState = oauthState.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? oauthState
        let authURL = "https://ticktick.com/oauth/authorize?client_id=\(Self.clientId)&redirect_uri=\(encodedRedirect)&response_type=code&scope=tasks:read%20tasks:write&state=\(encodedState)"
        if let url = URL(string: authURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Exchange an authorization code for access/refresh tokens.
    func exchangeCodeForToken(_ code: String) async throws {
        guard let tokenURL = URL(string: "https://ticktick.com/oauth/token") else {
            throw TickTickError.apiError(0, "Invalid token URL")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Basic auth with client_id:client_secret
        let credentials = "\(Self.clientId):\(Self.clientSecret)"
        let base64 = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

        let bodyStr = "code=\(code)&grant_type=authorization_code&redirect_uri=\(Self.redirectURI)"
        request.httpBody = bodyStr.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TickTickError.oauthFailed("Token exchange failed")
        }

        let tokenResponse = try JSONDecoder().decode(TickTickTokenResponse.self, from: data)
        accessToken = tokenResponse.accessToken
        refreshToken = tokenResponse.refreshToken ?? ""
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn ?? 86400))
    }

    // MARK: - Private Helpers

    private func ensureValidToken() async throws {
        guard !accessToken.isEmpty else {
            throw TickTickError.notConnected
        }
        guard let expiry = tokenExpiry, Date() >= expiry.addingTimeInterval(-60) else { return }

        // Token expired or about to expire — refresh
        guard !refreshToken.isEmpty else {
            throw TickTickError.tokenExpired
        }

        guard let tokenURL = URL(string: "https://ticktick.com/oauth/token") else {
            throw TickTickError.apiError(0, "Invalid token URL")
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(Self.clientId):\(Self.clientSecret)"
        let base64 = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")

        let bodyStr = "refresh_token=\(refreshToken)&grant_type=refresh_token"
        request.httpBody = bodyStr.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TickTickError.tokenExpired
        }

        let tokenResponse = try JSONDecoder().decode(TickTickTokenResponse.self, from: data)
        accessToken = tokenResponse.accessToken
        if let newRefresh = tokenResponse.refreshToken {
            refreshToken = newRefresh
        }
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn ?? 86400))
    }

    private func fetchProjects() async throws -> [TickTickProject] {
        let (data, _) = try await makeRequest(method: "GET", path: "/project")
        return try JSONDecoder().decode([TickTickProject].self, from: data)
    }

    private func fetchTasksInProject(_ project: TickTickProject) async throws -> [SyncTask] {
        let (data, _) = try await makeRequest(method: "GET", path: "/project/\(project.id)/data")
        let projectData = try JSONDecoder().decode(TickTickProjectData.self, from: data)

        return (projectData.tasks ?? []).map { task in
            mapToSyncTask(task, projectName: project.name)
        }
    }

    private func completeTask(projectId: String, taskId: String) async throws {
        try await makeRequest(method: "POST", path: "/project/\(projectId)/task/\(taskId)/complete")
    }

    private func resolveProjectId(for listName: String) async throws -> String? {
        let projects = try await fetchProjects()
        return projects.first(where: { $0.name.lowercased() == listName.lowercased() })?.id
    }

    @discardableResult
    private func makeRequest(method: String, path: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard !accessToken.isEmpty else {
            throw TickTickError.notConnected
        }

        guard let url = URL(string: baseURL + path) else {
            throw TickTickError.apiError(0, "Invalid URL: \(baseURL + path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TickTickError.apiError(0, "Invalid response")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return (data, httpResponse)
        case 401:
            throw TickTickError.tokenExpired
        case 429:
            throw TickTickError.apiError(429, "Rate limited")
        default:
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw TickTickError.apiError(httpResponse.statusCode, snippet)
        }
    }

    // MARK: - Mapping

    private func mapToSyncTask(_ task: TickTickTask, projectName: String) -> SyncTask {
        let priority = mapPriorityFromTickTick(task.priority)
        let dueDate = task.dueDate.flatMap { ISO8601DateFormatter().date(from: $0) }
        let isCompleted = task.status == 2

        return SyncTask(
            title: task.title,
            isCompleted: isCompleted,
            priority: priority,
            dueDate: dueDate,
            tags: [],  // TickTick Open API doesn't support tags
            targetList: projectName,
            notes: task.content?.isEmpty == false ? task.content : nil,
            remindersId: task.id,
            lastModified: Date()
        )
    }

    private func mapPriorityToTickTick(_ priority: SyncTask.Priority) -> Int {
        switch priority {
        case .high: return 5
        case .medium: return 3
        case .low: return 1
        case .none: return 0
        }
    }

    private func mapPriorityFromTickTick(_ priority: Int) -> SyncTask.Priority {
        switch priority {
        case 5: return .high
        case 3: return .medium
        case 1: return .low
        default: return .none
        }
    }
}

// MARK: - API Models

private struct TickTickTask: Codable {
    let id: String
    let title: String
    let content: String?
    let priority: Int
    let dueDate: String?
    let projectId: String?
    let status: Int  // 0 = normal, 2 = completed
}

private struct TickTickProject: Codable {
    let id: String
    let name: String
}

private struct TickTickProjectData: Codable {
    let tasks: [TickTickTask]?
}

private struct TickTickTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - Errors

// MARK: - Local OAuth Callback Server

enum TickTickOAuthServerError: LocalizedError {
    case socketCreationFailed
    case bindFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "Failed to create OAuth callback socket"
        case .bindFailed(let err):
            // EADDRINUSE = 48 on Darwin
            let detail = String(cString: strerror(err))
            return "Could not bind OAuth callback port: \(detail)"
        }
    }
}

/// Minimal HTTP server on localhost to receive the TickTick OAuth redirect.
/// Listens on a fixed port, extracts the `code` query parameter, calls the
/// completion handler, then shuts down.
///
/// IMPORTANT (#61): `start()` is synchronous up to the point the socket is
/// bound and listening. Only the `accept()` loop runs on a background queue.
/// The browser must NOT be opened until `start()` returns successfully —
/// otherwise the OAuth redirect can race past the unbound port and the
/// user sees `ERR_CONNECTION_REFUSED`.
class TickTickOAuthServer {
    private var serverSocket: Int32 = -1
    private let port: UInt16
    /// Called with the received `code` and `state` once a valid callback arrives.
    private let onCallback: (_ code: String, _ state: String?) -> Void
    private var listening = false

    init(port: UInt16, onCallback: @escaping (_ code: String, _ state: String?) -> Void) {
        self.port = port
        self.onCallback = onCallback
    }

    /// Bind + listen synchronously (so the caller knows the port is ready
    /// before opening the browser), then dispatch the accept loop in the
    /// background. Throws if socket creation or bind fails so the caller can
    /// avoid opening the browser to a dead callback URL.
    func start() throws {
        try bindAndListen()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        listening = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    private func bindAndListen() throws {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            debugLog("[TickTickOAuth] Failed to create socket")
            throw TickTickOAuthServerError.socketCreationFailed
        }

        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            let savedErrno = errno
            debugLog("[TickTickOAuth] Failed to bind to port \(port): \(String(cString: strerror(savedErrno)))")
            close(serverSocket)
            serverSocket = -1
            throw TickTickOAuthServerError.bindFailed(errno: savedErrno)
        }

        Darwin.listen(serverSocket, 1)
        listening = true
        debugLog("[TickTickOAuth] Listening on 127.0.0.1:\(port)")

        // Set a recv timeout so a hung browser doesn't block the accept loop forever.
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(serverSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func acceptLoop() {
        while listening {
            let clientSocket = accept(serverSocket, nil, nil)
            guard clientSocket >= 0 else { break }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)
            guard bytesRead > 0 else {
                close(clientSocket)
                continue
            }

            let request = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""

            // Extract the path from "GET /oauth/ticktick?code=xxx&state=yyy HTTP/1.1"
            if let firstLine = request.components(separatedBy: "\r\n").first,
               let pathPart = firstLine.components(separatedBy: " ").dropFirst().first,
               let components = URLComponents(string: pathPart),
               // Only accept the exact callback path — the previous code accepted
               // any path carrying `?code=` (GHSA-3q2g-hmqg-qj5r, H3).
               components.path == "/oauth/ticktick",
               let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
                let state = components.queryItems?.first(where: { $0.name == "state" })?.value

                // Send success response
                let html = """
                <html><body style="font-family:-apple-system,system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f7">
                <div style="text-align:center"><h1 style="color:#1d1d1f">Connected!</h1><p style="color:#86868b">TickTick is now connected to Remindian. You can close this tab.</p></div>
                </body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                _ = response.withCString { send(clientSocket, $0, Int(strlen($0)), 0) }
                close(clientSocket)

                onCallback(code, state)
                stop()
                return
            } else {
                // Not the callback we're looking for
                let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = response.withCString { send(clientSocket, $0, Int(strlen($0)), 0) }
                close(clientSocket)
            }
        }

        stop()
    }

    deinit {
        stop()
    }
}

enum TickTickError: LocalizedError {
    case notConnected
    case tokenExpired
    case oauthFailed(String)
    case apiError(Int, String)
    case projectNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to TickTick. Please connect your account in Settings."
        case .tokenExpired:
            return "TickTick session expired. Please reconnect your account in Settings."
        case .oauthFailed(let message):
            return "TickTick OAuth error: \(message)"
        case .apiError(let code, let message):
            return "TickTick API error (HTTP \(code)): \(message)"
        case .projectNotFound(let name):
            return "TickTick project not found: \(name)"
        }
    }
}
