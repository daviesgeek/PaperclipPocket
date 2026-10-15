import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct PaperclipAPI {
    private struct ErrorBody: Decodable { let error: String?; let message: String? }

    let configuration: AppConfiguration

    enum APIError: LocalizedError {
        case invalidURL
        case invalidResponse
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter an HTTPS Paperclip server URL."
            case .invalidResponse: return "Paperclip returned an unexpected response."
            case let .http(code, message):
                if code == 401 { return "Your Paperclip login is invalid or revoked. Reconnect in Settings." }
                if code == 403 { return "Access denied. Sign in with a board account allowed to use chat." }
                return "Paperclip error \(code): \(message)"
            }
        }
    }

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        let origin = configuration.paperclipURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = URL(string: origin), base.scheme == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              base.path.isEmpty || base.path == "/"
        else { throw APIError.invalidURL }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/api/" + path.split(separator: "/").map(String.init).joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url else { throw APIError.invalidURL }
        return result
    }

    func request<T: Decodable>(_ path: String,
                               method: String = "GET",
                               query: [URLQueryItem] = [],
                               body: [String: Any]? = nil) async throws -> T {
        let data = try await send(path, method: method, query: query, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// For endpoints whose shape varies by adapter (run lists, run logs).
    func rawJSON(_ path: String, query: [URLQueryItem] = []) async throws -> Any {
        let data = try await send(path, method: "GET", query: query, body: nil)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func send(_ path: String, method: String, query: [URLQueryItem], body: [String: Any]?) async throws -> Data {
        var request = URLRequest(url: try url(path, query: query))
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("Bearer \(configuration.boardToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
            let message = parsed?.message ?? parsed?.error ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.http(response.statusCode, String(message.prefix(250)))
        }
        return data
    }

    func companies() async throws -> [Company] {
        try await request("companies")
    }

    func issues(_ query: [URLQueryItem] = []) async throws -> [Issue] {
        try await request("companies/\(configuration.companyID)/issues", query: query)
    }

    func issue(_ id: String) async throws -> Issue {
        try await request("issues/\(id)")
    }

    func updateIssue(_ id: String, fields: [String: Any]) async throws -> Issue {
        try await request("issues/\(id)", method: "PATCH", body: fields)
    }

  func projects() async throws -> [Project] {
    try await request("companies/\(configuration.companyID)/projects")
    }

    func agents() async throws -> [Agent] {
        try await request("companies/\(configuration.companyID)/agents")
    }

    func chats() async throws -> [Issue] {
        try await request("companies/\(configuration.companyID)/chats")
    }

    // A GET on this endpoint returns JSON null until the first message.
    func existingChat(agentID: String) async throws -> Issue? {
        try await request("companies/\(configuration.companyID)/chats/\(agentID)")
    }

    func openChat(agentID: String) async throws -> Issue {
        try await request("companies/\(configuration.companyID)/chats/\(agentID)", method: "POST")
    }

    func comments(issueID: String) async throws -> [IssueComment] {
        try await request("issues/\(issueID)/comments", query: [URLQueryItem(name: "order", value: "asc"), URLQueryItem(name: "limit", value: "500")])
    }

    /// Marks the issue/chat read for the signed-in user.
    func markRead(issueID: String) async throws {
        _ = try await send("issues/\(issueID)/read", method: "POST", query: [], body: nil)
    }

    func attachments(issueID: String) async throws -> [IssueAttachment] {
        try await request("issues/\(issueID)/attachments")
    }

    func upload(_ file: PendingAttachment, issueID: String, commentID: String) async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: try url("companies/\(configuration.companyID)/issues/\(issueID)/attachments"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(configuration.boardToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let safeName = file.name.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"issueCommentId\"\r\n\r\n\(commentID)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(file.mimeType)\r\n\r\n".utf8))
        body.append(file.data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw APIError.http(response.statusCode, String((parsed?.message ?? parsed?.error ?? "Upload failed").prefix(250)))
        }
    }

    /// Absolute avatar URL at the requested point size (2x); the server may return a relative path.
    func avatarURL(for agent: Agent, size: CGFloat = 40) -> URL? {
        guard let base = try? url("") else { return nil }
        var resolved: URL?
        if let raw = agent.avatarUrl, !raw.isEmpty {
            resolved = URL(string: raw, relativeTo: base)?.absoluteURL
        } else if let palette = agent.appearance?.paletteId {
            let version = agent.appearance?.characterVersion ?? "cap-v1"
            resolved = URL(string: "/api/agent-avatars/\(version)/\(palette)/rest.png", relativeTo: base)?.absoluteURL
        }
        guard let resolved, var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else { return nil }
        let allowed = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256, 512]
        let pixels = allowed.first { CGFloat($0) >= size } ?? 512
        components.queryItems = [URLQueryItem(name: "size", value: String(pixels)), URLQueryItem(name: "scale", value: "2")]
        return components.url
    }

    /// Streams company events over the websocket, reconnecting until the consumer cancels.
    func liveEvents() -> AsyncStream<LiveEvent> {
        AsyncStream { continuation in
            let task = Task {
                var connections = 0
                while !Task.isCancelled {
                    if connections > 0 { continuation.yield(LiveEvent(type: LiveEvent.reconnectType)) }
                    connections += 1
                    if var components = (try? url("companies/\(configuration.companyID)/events/ws")).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) {
                        components.scheme = "wss"
                        if let wsURL = components.url {
                            var request = URLRequest(url: wsURL)
                            request.setValue("Bearer \(configuration.boardToken)", forHTTPHeaderField: "Authorization")
                            let socket = URLSession.shared.webSocketTask(with: request)
                            socket.resume()
                            while !Task.isCancelled {
                                guard let message = try? await socket.receive() else { break }
                                let data: Data?
                                switch message {
                                case let .string(text): data = text.data(using: .utf8)
                                case let .data(raw): data = raw
                                @unknown default: data = nil
                                }
                                if let data, let event = LiveEvent(data: data) { continuation.yield(event) }
                            }
                            socket.cancel(with: .goingAway, reason: nil)
                        }
                    }
                    try? await Task.sleep(for: .seconds(3))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func sendMessage(_ body: String, issueID: String, clientRequestID: UUID) async throws -> IssueComment {
        try await request("issues/\(issueID)/comments", method: "POST", body: [
            "body": body,
            "clientRequestId": clientRequestID.uuidString.lowercased()
        ])
    }
}
