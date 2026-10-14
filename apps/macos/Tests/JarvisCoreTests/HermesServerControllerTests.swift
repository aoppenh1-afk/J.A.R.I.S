import Foundation
import Darwin
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

private final class HermesTestProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HermesManagedProcessIdentity?

    init(_ identity: HermesManagedProcessIdentity) { value = identity }

    func identity() -> HermesManagedProcessIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func exit() {
        lock.lock()
        defer { lock.unlock() }
        value = nil
    }
}

@MainActor
final class HermesServerControllerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        HermesServerURLProtocol.handler = nil
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories = []
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
            executableOverride: executable.path, session: makeSession(), readinessTimeout: .seconds(2),
            managedProcessInspector: makeUnoccupiedInspector()
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
            readinessTimeout: .seconds(3),
            managedProcessInspector: makeUnoccupiedInspector()
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
            session: session,
            managedProcessInspector: HermesManagedProcessInspector(profileDirectory: URL(fileURLWithPath: "/missing/profile"))
        )

        do {
            try await controller.ensureAvailable()
            XCTFail("Expected an occupied managed endpoint error")
        } catch let error as HermesServerError {
            XCTAssertEqual(error, .managedEndpointOccupied)
        }
    }

    func testManagedEndpointReusesVerifiedAuthenticatedServerAfterAppRestart() async throws {
        HermesServerURLProtocol.handler = { request in
            if request.url?.path == "/health" {
                return (Self.response(for: request, status: 200), Data("{\"status\":\"ok\"}".utf8))
            }
            XCTAssertEqual(request.url?.path, "/v1/capabilities")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer app-key")
            return (Self.response(for: request, status: 200), Self.compatibleCapabilities())
        }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL,
            apiKey: "app-key",
            executableOverride: "/definitely/not/hermes",
            session: makeSession(),
            managedProcessInspector: try makeInspector()
        )

        try await controller.ensureAvailable()
        let status = await controller.processStatus()
        XCTAssertEqual(status.totalStartCount, 0)
        XCTAssertFalse(status.ownedProcessRunning)
        await controller.shutdown()
        try await controller.ensureAvailable()
        await controller.shutdown()
    }

    func testCompatibleAPIWithoutProfileOwnershipIsStillRejected() async throws {
        HermesServerURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/health", "Credentials must not be sent to an unverified listener")
            return (Self.response(for: request, status: 200), Self.compatibleCapabilities())
        }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL, apiKey: "app-key",
            session: makeSession(),
            managedProcessInspector: HermesManagedProcessInspector(profileDirectory: URL(fileURLWithPath: "/missing/profile"))
        )
        do {
            try await controller.ensureAvailable()
            XCTFail("An API response alone cannot attest the jarvis profile")
        } catch let error as HermesServerError {
            XCTAssertEqual(error, .managedEndpointOccupied)
        }
    }

    func testAuthenticatedServerWithLiveOwnerIsReusedWithoutSignalingIt() async throws {
        var inspector = try makeInspector(parentPID: 123)
        inspector.sendSignal = { _, _ in XCTFail("A live owner's gateway must not be signaled"); return false }
        HermesServerURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.compatibleCapabilities())
        }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL, apiKey: "app-key",
            session: makeSession(), managedProcessInspector: inspector
        )
        try await controller.ensureAvailable()
        await controller.shutdown()
    }

    func testWrongKeyNeverStopsGatewayWithLiveOwner() async throws {
        var inspector = try makeInspector(parentPID: 123)
        inspector.sendSignal = { _, _ in XCTFail("A live owner's gateway must not be signaled"); return false }
        HermesServerURLProtocol.handler = { request in
            (Self.response(for: request, status: request.url?.path == "/health" ? 200 : 401), Data())
        }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL, apiKey: "wrong-key",
            session: makeSession(), managedProcessInspector: inspector
        )
        do {
            try await controller.ensureAvailable()
            XCTFail("Expected authentication failure")
        } catch let error as HermesServerError {
            XCTAssertEqual(error, .managedEndpointOccupied)
        }
    }

    func testReusedGatewayExitNotifiesRecoveryOnce() async throws {
        var inspector = try makeInspector()
        let state = HermesTestProcessState(try XCTUnwrap(inspector.processIdentity(42)))
        inspector.processIdentity = { _ in state.identity() }
        HermesServerURLProtocol.handler = { request in
            (Self.response(for: request, status: 200), Self.compatibleCapabilities())
        }
        let exited = expectation(description: "Reused gateway exit triggers app recovery")
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL, apiKey: "app-key",
            session: makeSession(), onUnexpectedExit: { _ in exited.fulfill() },
            managedProcessInspector: inspector
        )
        try await controller.ensureAvailable()
        state.exit()
        await fulfillment(of: [exited], timeout: 3)
        let status = await controller.processStatus()
        XCTAssertEqual(status.unexpectedExitCount, 1)
        await controller.shutdown()
    }

    func testShutdownForcesUnresponsiveOwnedChildToExit() async throws {
        let executable = try makeWaitingExecutable()
        try """
        #!/bin/sh
        echo $$ > "${0%/*}/pid"
        trap '' TERM
        while :; do /bin/sleep 0.05; done

        """.write(to: executable, atomically: true, encoding: .utf8)
        HermesServerURLProtocol.handler = { request in
            if request.url?.path == "/health" { throw URLError(.cannotConnectToHost) }
            return (Self.response(for: request, status: 200), Self.compatibleCapabilities())
        }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL, apiKey: "test-key",
            executableOverride: executable.path, session: makeSession(), readinessTimeout: .seconds(2),
            shutdownTimeout: .milliseconds(100), managedProcessInspector: makeUnoccupiedInspector()
        )
        try await controller.ensureAvailable()
        let pidFile = executable.deletingLastPathComponent().appending(path: "pid")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        await controller.shutdown()
        XCTAssertNil(HermesManagedProcessInspector.readProcessIdentity(pid))
    }

    func testConcurrentStartupLaunchesOnlyOneGateway() async throws {
        let executable = try makeWaitingExecutable()
        HermesServerURLProtocol.handler = { request in
            Thread.sleep(forTimeInterval: 0.02)
            if request.url?.path == "/health" { throw URLError(.cannotConnectToHost) }
            return (Self.response(for: request, status: 200), Self.compatibleCapabilities())
        }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL, apiKey: "test-key",
            executableOverride: executable.path, session: makeSession(), readinessTimeout: .seconds(2),
            managedProcessInspector: makeUnoccupiedInspector()
        )
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<10 { group.addTask { try await controller.ensureAvailable() } }
                try await group.waitForAll()
            }
            let status = await controller.processStatus()
            XCTAssertEqual(status.totalStartCount, 1)
            XCTAssertTrue(status.ownedProcessRunning)
        } catch {
            await controller.shutdown()
            throw error
        }
        await controller.shutdown()
    }

    func testVerifiedOrphanWithOldKeyIsReplacedAutomatically() async throws {
        let executable = try makeWaitingExecutable()
        var inspector = try makeInspector()
        let state = HermesTestProcessState(try XCTUnwrap(inspector.processIdentity(42)))
        inspector.processIdentity = { _ in state.identity() }
        inspector.sendSignal = { pid, signal in
            XCTAssertEqual(pid, 42)
            XCTAssertEqual(signal, SIGTERM)
            state.exit()
            return true
        }
        HermesServerURLProtocol.handler = { request in
            if request.url?.path == "/health" {
                if state.identity() == nil { throw URLError(.cannotConnectToHost) }
                return (Self.response(for: request, status: 200), Data())
            }
            return (Self.response(for: request, status: state.identity() == nil ? 200 : 401), Self.compatibleCapabilities())
        }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL, apiKey: "new-key",
            executableOverride: executable.path, session: makeSession(), readinessTimeout: .seconds(2),
            managedProcessInspector: inspector
        )
        do {
            try await controller.ensureAvailable()
            let status = await controller.processStatus()
            XCTAssertEqual(status.totalStartCount, 1)
            XCTAssertTrue(status.ownedProcessRunning)
            XCTAssertNil(state.identity())
        } catch {
            await controller.shutdown()
            throw error
        }
        await controller.shutdown()
    }

    func testShutdownCancelsStartupAndLeavesNoChildBehind() async throws {
        let executable = try makeWaitingExecutable()
        HermesServerURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL, apiKey: "test-key",
            executableOverride: executable.path, session: makeSession(), readinessTimeout: .seconds(30),
            managedProcessInspector: makeUnoccupiedInspector()
        )
        let startup = Task { try await controller.ensureAvailable() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await controller.processStatus().totalStartCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await controller.shutdown()
        do {
            try await startup.value
            XCTFail("Shutdown should cancel pending readiness")
        } catch is CancellationError {
            // Expected, rather than waiting for the thirty-second readiness deadline.
        }
        let status = await controller.processStatus()
        XCTAssertFalse(status.ownedProcessRunning)
        XCTAssertEqual(status.totalStartCount, 1)
        XCTAssertEqual(status.unexpectedExitCount, 0)
    }

    func testShutdownWaitsForOwnedGatewayToExitBeforeReturning() async throws {
        let executable = try makeWaitingExecutable()
        HermesServerURLProtocol.handler = { request in
            if request.url?.path == "/health" { throw URLError(.cannotConnectToHost) }
            return (Self.response(for: request, status: 200), Self.compatibleCapabilities())
        }
        let controller = HermesServerController(
            baseURL: HermesRuntimeConfiguration.managedBaseURL, apiKey: "test-key",
            executableOverride: executable.path, session: makeSession(), readinessTimeout: .seconds(2),
            managedProcessInspector: makeUnoccupiedInspector()
        )
        try await controller.ensureAvailable()
        let pidFile = executable.deletingLastPathComponent().appending(path: "pid")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        await controller.shutdown()
        XCTAssertNil(HermesManagedProcessInspector.readProcessIdentity(pid), "Shutdown must finish before quitting the app")
        let status = await controller.processStatus()
        XCTAssertFalse(status.ownedProcessRunning)
        XCTAssertEqual(status.unexpectedExitCount, 0)
    }

    private func makeWaitingExecutable() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "jarvis-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let executable = directory.appending(path: "hermes")
        try """
        #!/bin/sh
        echo $$ > "${0%/*}/pid"
        trap 'exit 0' TERM
        while :; do /bin/sleep 0.05; done

        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func makeUnoccupiedInspector() -> HermesManagedProcessInspector {
        HermesManagedProcessInspector(profileDirectory: URL(fileURLWithPath: "/missing/profile"))
    }

    private func makeInspector(parentPID: Int32 = 1) throws -> HermesManagedProcessInspector {
        let directory = FileManager.default.temporaryDirectory.appending(path: "jarvis-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let data = try JSONSerialization.data(withJSONObject: [
            "pid": 42, "kind": "hermes-gateway", "start_time": 12345,
            "hermes_home": directory.path,
            "argv": ["hermes", "gateway", "run", "--force", "--external-supervisor"],
        ])
        try data.write(to: directory.appending(path: "gateway.pid"))
        var inspector = HermesManagedProcessInspector(profileDirectory: directory)
        inspector.processIdentity = { _ in
            HermesManagedProcessIdentity(pid: 42, parentPID: parentPID, userID: getuid(), startTime: 12345)
        }
        inspector.listenerPIDs = { _ in [42] }
        inspector.sendSignal = { _, _ in XCTFail("Unexpected signal to fixture process"); return false }
        return inspector
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
