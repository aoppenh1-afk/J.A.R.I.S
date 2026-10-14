import Darwin
import Foundation
import XCTest
@testable import JarvisCore

final class HermesManagedProcessTests: XCTestCase {
    private var directory: URL!
    private let identity = HermesManagedProcessIdentity(pid: 42, parentPID: 1, userID: getuid(), startTime: 12345)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "jarvis-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeRecord()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testVerifiesProfileProcessAndPortTogether() {
        XCTAssertEqual(inspector().verifiedListener(at: HermesRuntimeConfiguration.managedBaseURL), identity)
    }

    func testRejectsRecycledPID() {
        var inspector = inspector()
        inspector.processIdentity = { _ in
            HermesManagedProcessIdentity(pid: 42, parentPID: 1, userID: getuid(), startTime: 67890)
        }
        XCTAssertNil(inspector.verifiedListener(at: HermesRuntimeConfiguration.managedBaseURL))
    }

    func testRejectsDifferentProfile() throws {
        try writeRecord(overrides: ["hermes_home": "/tmp/different-profile"])
        XCTAssertNil(inspector().verifiedListener(at: HermesRuntimeConfiguration.managedBaseURL))
    }

    func testRejectsDifferentListenerAndAmbiguousListeners() {
        for pids: Set<Int32> in [[43], [42, 43], []] {
            var inspector = inspector()
            inspector.listenerPIDs = { _ in pids }
            XCTAssertNil(inspector.verifiedListener(at: HermesRuntimeConfiguration.managedBaseURL))
        }
    }

    func testRejectsOtherUser() {
        var inspector = inspector()
        inspector.processIdentity = { _ in
            HermesManagedProcessIdentity(pid: 42, parentPID: 1, userID: getuid() + 1, startTime: 12345)
        }
        XCTAssertNil(inspector.verifiedListener(at: HermesRuntimeConfiguration.managedBaseURL))
    }

    func testRejectsUnsupervisedOrNonGatewayRecord() throws {
        for argv in [["hermes", "gateway", "run"], ["hermes", "gateway", "status", "--external-supervisor"]] {
            try writeRecord(overrides: ["argv": argv])
            XCTAssertNil(inspector().verifiedListener(at: HermesRuntimeConfiguration.managedBaseURL))
        }
    }

    func testRejectsLegacyOrMalformedRecord() throws {
        let record = directory.appending(path: "gateway.pid")
        for text in ["42", "{}", "not JSON"] {
            try text.write(to: record, atomically: true, encoding: .utf8)
            XCTAssertNil(inspector().verifiedListener(at: HermesRuntimeConfiguration.managedBaseURL))
        }
    }

    func testSignalRechecksIdentityBeforeTouchingOrphan() {
        var inspector = inspector()
        inspector.processIdentity = { _ in
            HermesManagedProcessIdentity(pid: 42, parentPID: 1, userID: getuid(), startTime: 67890)
        }
        inspector.sendSignal = { _, _ in XCTFail("A recycled PID must never be signaled"); return false }
        XCTAssertFalse(inspector.signalOrphan(identity, signal: SIGTERM))
    }

    func testNativeIdentityMatchesCurrentProcess() throws {
        let identity = try XCTUnwrap(HermesManagedProcessInspector.readProcessIdentity(getpid()))
        XCTAssertEqual(identity.pid, getpid())
        XCTAssertEqual(identity.parentPID, getppid())
        XCTAssertEqual(identity.userID, getuid())
        XCTAssertGreaterThan(identity.startTime, 0)
        XCTAssertEqual(HermesManagedProcessInspector.readProcessIdentity(getpid()), identity)
    }

    private func inspector() -> HermesManagedProcessInspector {
        var inspector = HermesManagedProcessInspector(profileDirectory: directory)
        let identity = identity
        inspector.processIdentity = { _ in identity }
        inspector.listenerPIDs = { _ in [42] }
        return inspector
    }

    private func writeRecord(overrides: [String: Any] = [:]) throws {
        var record: [String: Any] = [
            "pid": 42, "kind": "hermes-gateway", "start_time": 12345,
            "hermes_home": directory.path,
            "argv": ["hermes", "gateway", "run", "--force", "--external-supervisor"],
        ]
        record.merge(overrides) { _, new in new }
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appending(path: "gateway.pid"))
    }
}
