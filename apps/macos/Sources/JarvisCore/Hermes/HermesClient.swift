import Foundation

public enum JarvisHermesInstructions {
    public static let system = """
    J.A.R.V.I.S. is a native macOS voice assistant. When the user asks to open, launch, or show a website in "my browser", "the browser", or their default browser, they mean their visible macOS browser, not Hermes's isolated automation browser. Use the terminal tool to run /usr/bin/open with the safely shell-quoted http or https URL. Check the terminal result and report success only when the command exits successfully. Never claim browser_navigate opened the user's browser; browser_navigate controls an isolated automation browser and should be used only for web research or page interaction.
    """
}

public protocol HermesServicing: Sendable {
    func health() async throws -> [String: String]
    func capabilities() async throws -> Data
    func createRun(input: String, sessionID: String?) async throws -> HermesRun
    func streamEvents(runID: String) async throws -> AsyncThrowingStream<HermesEvent, Error>
    func getRun(runID: String) async throws -> HermesRun
    func stopRun(runID: String) async throws
    func respondToApproval(runID: String, choice: HermesApprovalChoice) async throws
}

public actor HermesClient: HermesServicing {
    private let baseURL: URL
    private let apiKey: String?
    private let sessionKey: String
    private let instructions: String?
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        sessionKey: String,
        instructions: String? = JarvisHermesInstructions.system,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sessionKey = sessionKey
        self.instructions = instructions
        self.session = session
    }

    public func health() async throws -> [String: String] {
        let data = try await request(path: "/health")
        return (try? decoder.decode([String: String].self, from: data)) ?? ["status": "ok"]
    }

    public func capabilities() async throws -> Data {
        try await request(path: "/v1/capabilities")
    }

    public func createRun(input: String, sessionID: String?) async throws -> HermesRun {
        var body = ["input": input]
        if let sessionID { body["session_id"] = sessionID }
        if let instructions { body["instructions"] = instructions }
        let data = try await request(path: "/v1/runs", method: "POST", json: body, expectedStatus: 202)
        return try decoder.decode(HermesRun.self, from: data)
    }

    public func streamEvents(runID: String) async throws -> AsyncThrowingStream<HermesEvent, Error> {
        let request = try makeRequest(path: "/v1/runs/\(runID)/events", accept: "text/event-stream")
        let session = self.session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else {
                        throw HermesClientError.invalidResponse
                    }
                    guard response.statusCode == 200 else {
                        throw HermesClientError.http(status: response.statusCode, message: "Unable to open event stream")
                    }

                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        if let event = try parser.consume(line: line) {
                            continuation.yield(event)
                        } else if line.hasPrefix("data:"),
                                  let event = try parser.consume(line: "") {
                            // URLSession.AsyncBytes.lines may omit empty SSE separator
                            // lines, while Hermes emits one complete JSON object per data line.
                            continuation.yield(event)
                        }
                    }
                    if let event = try parser.finish() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func getRun(runID: String) async throws -> HermesRun {
        let data = try await request(path: "/v1/runs/\(runID)")
        return try decoder.decode(HermesRun.self, from: data)
    }

    public func stopRun(runID: String) async throws {
        _ = try await request(path: "/v1/runs/\(runID)/stop", method: "POST")
    }

    public func respondToApproval(runID: String, choice: HermesApprovalChoice) async throws {
        _ = try await request(
            path: "/v1/runs/\(runID)/approval",
            method: "POST",
            json: ["choice": choice.rawValue]
        )
    }

    private func request(
        path: String,
        method: String = "GET",
        json: [String: String]? = nil,
        expectedStatus: Int = 200
    ) async throws -> Data {
        var request = try makeRequest(path: path)
        request.httpMethod = method
        if let json {
            request.httpBody = try encoder.encode(json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw HermesClientError.invalidResponse
        }
        guard response.statusCode == expectedStatus else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown Hermes API error"
            throw HermesClientError.http(status: response.statusCode, message: message)
        }
        return data
    }

    private func makeRequest(path: String, accept: String = "application/json") throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw HermesClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
