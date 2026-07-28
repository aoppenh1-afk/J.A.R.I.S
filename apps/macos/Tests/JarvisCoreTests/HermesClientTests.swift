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
}
