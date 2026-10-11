import Foundation
import XCTest
@testable import JarvisCore

private final class HermesClientURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let result = try Self.handler?(request) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func hermesRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { throw URLError(.zeroByteResource) }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

@MainActor
final class HermesClientTests: XCTestCase {
    override func tearDown() {
        HermesClientURLProtocol.handler = nil
        super.tearDown()
    }

    func testEveryAuthenticatedRouteRejectsRemoteEndpointsBeforeSendingARequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HermesClientURLProtocol.self]
        HermesClientURLProtocol.handler = { _ in
            XCTFail("No request may be sent to an invalid endpoint")
            throw URLError(.badURL)
        }
        let client = HermesClient(
            baseURL: URL(string: "https://outside.invalid")!, apiKey: "dummy-key",
            sessionKey: "dummy-session", session: URLSession(configuration: configuration)
        )
        let operations: [() async throws -> Void] = [
            { _ = try await client.health() },
            { _ = try await client.capabilities() },
            { _ = try await client.modelCatalog(refresh: true) },
            { _ = try await client.createRun(input: "test", sessionID: nil) },
            { _ = try await client.streamEvents(runID: "run-1") },
            { _ = try await client.getRun(runID: "run-1") },
            { try await client.stopRun(runID: "run-1") },
            { try await client.respondToApproval(runID: "run-1", choice: .deny) },
        ]
        for operation in operations {
            do {
                try await operation()
                XCTFail("Expected loopback validation")
            } catch let error as AppConfigError {
                XCTAssertEqual(error, .hermesMustUseLoopback)
            }
        }
    }

    func testRedirectPolicyRejectsRemoteDestinationWithSessionHeaders() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let originalURL = URL(string: "http://127.0.0.1:8643/api/model/options")!
        let task = session.dataTask(with: originalURL)
        let response = HTTPURLResponse(url: originalURL, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var redirected = URLRequest(url: URL(string: "https://outside.invalid/models")!)
        redirected.setValue("dummy-session", forHTTPHeaderField: "X-Hermes-Session-Key")
        redirected.setValue("Bearer dummy-key", forHTTPHeaderField: "Authorization")
        let policy = HermesRedirectPolicy()
        let rejected = await policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected)
        XCTAssertNil(rejected)
        redirected.url = URL(string: "http://localhost:8643/api/model/options/")!
        let allowed = await policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected)
        XCTAssertEqual(allowed?.url, redirected.url)
    }

    func testRunInstructionsDistinguishDefaultBrowserFromAutomationBrowser() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HermesClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        HermesClientURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/runs")
            let body = try hermesRequestBody(request)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            XCTAssertEqual(payload["input"], "Open example.com in my browser.")
            XCTAssertEqual(payload["session_id"], "browser-test")
            XCTAssertTrue(payload["instructions"]?.contains("/usr/bin/open") == true)
            XCTAssertTrue(payload["instructions"]?.contains("browser_navigate") == true)
            XCTAssertTrue(payload["instructions"]?.contains("<jarvis_ui>") == true)
            XCTAssertTrue(payload["instructions"]?.contains("follow_up_prompts") == true)
            XCTAssertTrue(payload["instructions"]?.contains("changed file") == true)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 202,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data("{\"run_id\":\"run-1\",\"status\":\"started\",\"session_id\":\"browser-test\"}".utf8)
            )
        }

        let client = HermesClient(
            baseURL: URL(string: "http://127.0.0.1:8642")!,
            apiKey: "secret",
            sessionKey: "session-key",
            session: session
        )
        let run = try await client.createRun(
            input: "Open example.com in my browser.",
            sessionID: "browser-test"
        )

        XCTAssertEqual(run.runID, "run-1")
    }

    func testModelOverridesAreSentOnNextRunAndCanReturnToDefault() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HermesClientURLProtocol.self]
        let client = HermesClient(
            baseURL: URL(string: "http://127.0.0.1:8643")!, apiKey: "test-secret",
            sessionKey: "test-session", session: URLSession(configuration: configuration)
        )
        var payloads: [[String: String]] = []
        HermesClientURLProtocol.handler = { request in
            payloads.append(try XCTUnwrap(JSONSerialization.jsonObject(with: hermesRequestBody(request)) as? [String: String]))
            return (HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!,
                    Data("{\"run_id\":\"run-model\",\"status\":\"queued\"}".utf8))
        }
        await client.setModelSelection(.init(provider: " anthropic ", model: " claude-test "))
        _ = try await client.createRun(input: "Hello", sessionID: nil)
        await client.setModelSelection(.init())
        _ = try await client.createRun(input: "Hello again", sessionID: nil)
        XCTAssertEqual(payloads[0]["provider"], "anthropic")
        XCTAssertEqual(payloads[0]["model"], "claude-test")
        XCTAssertNil(payloads[1]["provider"])
        XCTAssertNil(payloads[1]["model"])
    }

    func testModelCatalogUsesAuthenticatedHermesInventoryAndExcludesLockedModels() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HermesClientURLProtocol.self]
        let client = HermesClient(
            baseURL: URL(string: "http://127.0.0.1:8643")!, apiKey: "test-secret",
            sessionKey: "test-session", session: URLSession(configuration: configuration)
        )
        HermesClientURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/model/options")
            XCTAssertEqual(request.url?.query, "refresh=true")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"model":"model-a","provider":"nous","providers":[{"slug":"nous","name":"Nous","models":["model-a","model-b"],"authenticated":true,"unavailable_models":["model-b"]},{"slug":"other","name":"Other","models":[],"authenticated":false}]}"#.utf8))
        }
        let catalog = try await client.modelCatalog(refresh: true)
        XCTAssertEqual(catalog.provider, "nous")
        XCTAssertEqual(catalog.providers[0].availableModels, ["model-a"])
        XCTAssertTrue(catalog.providers[0].isSelectable)
        XCTAssertFalse(catalog.providers[1].isSelectable)
    }
}
