import XCTest
@testable import JarvisCore

final class AudioSignalTests: XCTestCase {
    func testSilenceAndLowLevelNoiseAreRejected() {
        XCTAssertTrue(AudioSignal.isLikelySilent([Float](repeating: 0, count: 16_000)))
        XCTAssertTrue(AudioSignal.isLikelySilent([Float](repeating: 0.001, count: 16_000)))
    }

    func testSpeechLevelSignalIsAccepted() {
        XCTAssertFalse(AudioSignal.isLikelySilent([Float](repeating: 0.02, count: 16_000)))
    }

    func testCaptureProfilesApplyIncreasingNoiseThresholds() {
        let roomNoise = [Float](repeating: 0.004, count: 16_000)

        XCTAssertFalse(AudioSignal.isLikelySilent(
            roomNoise,
            threshold: AppConfig.CaptureProfile.quiet.silenceRMSThreshold
        ))
        XCTAssertFalse(AudioSignal.isLikelySilent(
            roomNoise,
            threshold: AppConfig.CaptureProfile.normal.silenceRMSThreshold
        ))
        XCTAssertTrue(AudioSignal.isLikelySilent(
            roomNoise,
            threshold: AppConfig.CaptureProfile.noisy.silenceRMSThreshold
        ))
    }
}
