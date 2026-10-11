import Foundation
import XCTest
@testable import JarvisCore

private final class HermesServerURLProtocol: URLProtocol, @unchecked Sendable {
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

@MainActor
final class HermesServerControllerTests: XCTestCase {
    override func tearDown() {
        HermesServerURLProtocol.handler = nil
        super.tearDown()
    }

    func testLaunchArgumentsSelectJarvisProfile() {
        XCTAssertEqual(
            HermesServerController.launchArguments(),
            ["-p", "jarvis", "gateway", "run", "--force", "--external-supervisor"]
        )
    }

    func testReadyThenCrashCyclesRemainRateLimited() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "jarvis-crash-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appending(path: "hermes")
        let exitMarker = directory.appending(path: "exit")
        try """
        #!/bin/sh
        while [ ! -f "${0%/*}/exit" ]; do /bin/sleep 0.01; done
        exit 23

        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        HermesServerURLProtocol.handler = { request in
            if request.url?.path == "/health" { throw URLError(.cannotConnectToHost) }
            return (Self.response(for: request, status: 200), Self.compatibleCapabilities())
        }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL, apiKey: "test-key",
            executableOverride: executable.path, session: makeSession(), readinessTimeout: .seconds(2)
        )
        do {
            for count in 1...3 {
                try await controller.ensureAvailable()
                let ready = await controller.processStatus()
                XCTAssertTrue(ready.ownedProcessRunning)
                XCTAssertEqual(ready.totalStartCount, count)
                try Data().write(to: exitMarker)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while await controller.processStatus().unexpectedExitCount < count, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let crashed = await controller.processStatus()
                XCTAssertEqual(crashed.unexpectedExitCount, count)
                XCTAssertFalse(crashed.ownedProcessRunning)
                try FileManager.default.removeItem(at: exitMarker)
            }
            do {
                try await controller.ensureAvailable()
                XCTFail("A fourth ready-then-crash launch must be rejected")
            } catch let error as HermesServerError {
                XCTAssertEqual(error, .restartRateLimited)
            }
            let limited = await controller.processStatus()
            XCTAssertEqual(limited.totalStartCount, 3)
        } catch {
            await controller.shutdown()
            throw error
        }
        await controller.shutdown()
    }

    func testRemoteReadinessNeverSendsCredentials() async throws {
        HermesServerURLProtocol.handler = { _ in
            XCTFail("A remote endpoint must be rejected before a request is sent")
            throw URLError(.badURL)
        }
        let controller = HermesServerController(
            baseURL: URL(string: "https://outside.invalid")!, apiKey: "test-key", session: makeSession()
        )
        do {
            try await controller.ensureAvailable()
            XCTFail("Expected loopback validation")
        } catch let error as AppConfigError {
            XCTAssertEqual(error, .hermesMustUseLoopback)
        }
    }

    func testFastLauncherExitReportsItsOutputWithoutWaitingForDeadline() async throws {
        HermesServerURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("hermes")
        try "#!/bin/sh\necho \"Profile 'jarvis' does not get a gateway of its own.\"\nexit 78\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL,
            apiKey: "test-key",
            executableOverride: executable.path,
            session: makeSession(),
            readinessTimeout: .seconds(3)
        )
        let start = ContinuousClock.now
        do {
            try await controller.ensureAvailable()
            XCTFail("Expected the launcher to exit")
        } catch let error as HermesServerError {
            guard case .exitedBeforeReadyWithMessage(let status, let message) = error else {
                return XCTFail("Expected Hermes output, got \(error)")
            }
            XCTAssertEqual(status, 78)
            XCTAssertTrue(message.contains("does not get a gateway of its own"))
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testManagedLaunchEnvironmentOverridesProfileListenerValues() {
        let environment = HermesServerController.managedLaunchEnvironment(
            from: [
                "PATH": "/usr/bin",
                "API_SERVER_ENABLED": "0",
                "API_SERVER_HOST": "0.0.0.0",
                "API_SERVER_PORT": "8642",
                "API_SERVER_KEY": "stale-key",
                "GATEWAY_MULTIPLEX_PROFILES": "1",
            ],
            host: "127.0.0.1",
            port: 8643,
            apiKey: "app-key"
        )

        XCTAssertEqual(environment["API_SERVER_ENABLED"], "1")
        XCTAssertEqual(environment["API_SERVER_HOST"], "127.0.0.1")
        XCTAssertEqual(environment["API_SERVER_PORT"], "8643")
        XCTAssertEqual(environment["API_SERVER_KEY"], "app-key")
        XCTAssertEqual(environment["GATEWAY_MULTIPLEX_PROFILES"], "0")
    }

    func testManagedEndpointRejectsPreexistingHealthResponse() async throws {
        let session = makeSession()
        HermesServerURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/health")
            return (Self.response(for: request, status: 200), Data("{\"status\":\"ok\"}".utf8))
        }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL,
            apiKey: "app-key",
            executableOverride: "/definitely/not/hermes",
            session: session
        )

        do {
            try await controller.ensureAvailable()
            XCTFail("Expected an occupied managed endpoint error")
        } catch let error as HermesServerError {
            XCTAssertEqual(error, .managedEndpointOccupied)
        }
    }

    func testCustomEndpointRequiresAuthenticatedCompatibleCapabilities() async throws {
        let session = makeSession()
        HermesServerURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/capabilities")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer operator-key")
            return (Self.response(for: request, status: 200), Self.compatibleCapabilities())
        }
        let controller = HermesServerController(
            baseURL: URL(string: "http://127.0.0.1:9999")!,
            apiKey: "operator-key",
            executableOverride: "/definitely/not/hermes",
            session: session
        )

        try await controller.ensureAvailable()
        let status = await controller.processStatus()
        XCTAssertEqual(status.totalStartCount, 0)
        XCTAssertFalse(status.ownedProcessRunning)
    }

    func testCustomEndpointRejectsAuthenticationFailure() async throws {
        let session = makeSession()
        HermesServerURLProtocol.handler = { request in
            (Self.response(for: request, status: 401), Data())
        }
        let controller = HermesServerController(
            baseURL: URL(string: "http://127.0.0.1:9999")!,
            apiKey: "wrong-key",
            executableOverride: "/definitely/not/hermes",
            session: session
        )

        do {
            try await controller.ensureAvailable()
            XCTFail("Expected the custom endpoint to be rejected")
        } catch let error as HermesServerError {
            XCTAssertEqual(error, .customEndpointUnavailable)
        }
    }

    func testCapabilitiesValidatorRejectsGenericHealthPayload() {
        XCTAssertTrue(HermesServerController.isCompatibleCapabilitiesResponse(Self.compatibleCapabilities()))
        XCTAssertFalse(HermesServerController.isCompatibleCapabilitiesResponse(Data("{\"status\":\"ok\"}".utf8)))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HermesServerURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private static func compatibleCapabilities() -> Data {
        Data("""
        {
          "object": "hermes.api_server.capabilities",
          "endpoints": {
            "runs": {},
            "run_events": {},
            "run_status": {},
            "run_stop": {},
            "run_approval": {}
          },
          "features": {
            "run_submission": true,
            "run_events_sse": true,
            "run_status": true,
            "run_stop": true,
            "run_approval_response": true
          }
        }
        """.utf8)
    }
}
