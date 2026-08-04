import XCTest
@testable import JarvisCore

final class RuntimeHealthTests: XCTestCase {
    func testRecoveryPolicyIsBoundedAndOneIndexed() {
        let policy = RecoveryPolicy(delays: [.zero, .milliseconds(100), .seconds(1)])

        XCTAssertEqual(policy.maximumAttempts, 3)
        XCTAssertEqual(policy.delay(forAttempt: 1), .zero)
        XCTAssertEqual(policy.delay(forAttempt: 2), .milliseconds(100))
        XCTAssertEqual(policy.delay(forAttempt: 3), .seconds(1))
        XCTAssertNil(policy.delay(forAttempt: 0))
        XCTAssertNil(policy.delay(forAttempt: 4))
    }

    func testHermesRestartLimiterRejectsBurstAndRecoversAfterWindow() {
        var limiter = RestartRateLimiter(maximumStarts: 3, window: 60)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(limiter.recordStartIfAllowed(now: start))
        XCTAssertTrue(limiter.recordStartIfAllowed(now: start.addingTimeInterval(1)))
        XCTAssertTrue(limiter.recordStartIfAllowed(now: start.addingTimeInterval(2)))
        XCTAssertFalse(limiter.recordStartIfAllowed(now: start.addingTimeInterval(3)))
        XCTAssertTrue(limiter.recordStartIfAllowed(now: start.addingTimeInterval(61)))
    }

    func testHermesRestartLimiterResetAllowsImmediateRestart() {
        var limiter = RestartRateLimiter(maximumStarts: 1, window: 60)
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(limiter.recordStartIfAllowed(now: now))
        XCTAssertFalse(limiter.recordStartIfAllowed(now: now.addingTimeInterval(1)))

        limiter.reset()

        XCTAssertTrue(limiter.recordStartIfAllowed(now: now.addingTimeInterval(2)))
    }

    func testHermesServerErrorProvidesLocalizedDescription() {
        XCTAssertEqual(
            HermesServerError.restartRateLimited.localizedDescription,
            "Hermes restarted too frequently. Automatic restart is temporarily paused."
        )
    }

    func testHermesLaunchEnvironmentFindsUserAndHomebrewTools() {
        let inherited = ["PATH": "/usr/bin:/opt/homebrew/bin:/custom/bin"]

        let environment = HermesServerController.launchEnvironment(from: inherited)
        let paths = environment["PATH"]?.split(separator: ":").map(String.init)

        XCTAssertEqual(paths, [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/custom/bin",
        ])
    }

    func testRuntimeHealthStartsContentFreeAndUnknown() {
        let health = RuntimeHealth()

        XCTAssertEqual(health.network, .unknown)
        XCTAssertEqual(health.hermes, .unknown)
        XCTAssertEqual(health.audio, .unknown)
        XCTAssertEqual(health.microphone, .unknown)
        XCTAssertEqual(health.recoveryAttempt, 0)
    }
}
