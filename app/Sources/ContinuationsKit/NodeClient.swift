// HTTP + SSE client for one node. The only layer that knows the wire.

import Foundation

public struct NodeClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    private static let decoder = JSONDecoder()

    private func get<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.decoder.decode(type, from: data)
    }

    public func node() async throws -> NodeInfo {
        try await get(NodeInfo.self, "/v1/node")
    }

    public func queue() async throws -> QueueSnapshot {
        try await get(QueueSnapshot.self, "/v1/queue")
    }

    public func reviews() async throws -> [ReviewItem] {
        try await get(ReviewPage.self, "/v1/reviews").reviews
    }

    public func sessions() async throws -> [SupervisedSession] {
        try await get(SessionPage.self, "/v1/sessions").sessions
    }

    public func transcript(sessionRef: String,
                           limit: Int = 40) async throws -> Transcript {
        let escaped = sessionRef.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? sessionRef
        return try await get(Transcript.self,
                             "/v1/sessions/\(escaped)/transcript?limit=\(limit)")
    }

    public func tasks() async throws -> [TaskInfo] {
        struct Page: Decodable { let tasks: [TaskInfo] }
        return try await get(Page.self, "/v1/tasks").tasks
    }

    public func taskDetail(_ taskID: String) async throws -> TaskInfo {
        try await get(TaskInfo.self, "/v1/tasks/\(taskID)")
    }

    public func log(task: String? = nil, run: String? = nil,
                    after: Int? = nil, limit: Int = 200) async throws -> [EventRow] {
        var query = ["limit=\(limit)"]
        if let task { query.append("task=\(task)") }
        if let run { query.append("run=\(run)") }
        if let after { query.append("after=\(after)") }
        return try await get(EventPage.self, "/v1/log?" + query.joined(separator: "&")).events
    }

    public func prompts(task: String, run: String) async throws -> [PromptInfo] {
        try await get(PromptPage.self, "/v1/tasks/\(task)/runs/\(run)/prompts").prompts
    }

    public func promptText(task: String, run: String, name: String) async throws -> String {
        guard let url = URL(string: "/v1/tasks/\(task)/runs/\(run)/prompts/\(name)",
                            relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The SSE tail of the events table. The stream ends when the server
    /// closes or the connection drops; callers reconnect with the last
    /// delivered id as `after`.
    public func events(after: Int) -> AsyncThrowingStream<EventRow, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "/v1/events?after=\(after)",
                                        relativeTo: baseURL) else {
                        throw URLError(.badURL)
                    }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 3600 * 24
                    let config = URLSessionConfiguration.ephemeral
                    config.timeoutIntervalForRequest = 3600 * 24
                    config.timeoutIntervalForResource = 3600 * 24 * 7
                    let streamSession = URLSession(configuration: config)
                    defer { streamSession.invalidateAndCancel() }
                    let (bytes, response) = try await streamSession.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = Data(line.dropFirst("data: ".count).utf8)
                        let row = try Self.decoder.decode(EventRow.self, from: json)
                        continuation.yield(row)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
