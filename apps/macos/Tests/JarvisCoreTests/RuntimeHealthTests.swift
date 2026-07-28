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

    func testRuntimeHealthStartsContentFreeAndUnknown() {
        let health = RuntimeHealth()

        XCTAssertEqual(health.network, .unknown)
        XCTAssertEqual(health.hermes, .unknown)
        XCTAssertEqual(health.audio, .unknown)
        XCTAssertEqual(health.microphone, .unknown)
        XCTAssertEqual(health.recoveryAttempt, 0)
    }
}
