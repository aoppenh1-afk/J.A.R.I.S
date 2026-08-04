import Foundation
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

    func testFFTAnalyzerSeparatesLowMidAndHighFrequencyEnergy() {
        let low = AudioCaptureSignal.analyze(
            samples: toneMixture([120, 240, 420, 600]),
            sampleRate: 16_000
        ).bands
        XCTAssertGreaterThan(low.low, low.mid)
        XCTAssertGreaterThan(low.low, low.high)

        let mid = AudioCaptureSignal.analyze(
            samples: toneMixture([800, 1_200, 1_800, 2_500, 3_000]),
            sampleRate: 16_000
        ).bands
        XCTAssertGreaterThan(mid.mid, mid.low)
        XCTAssertGreaterThan(mid.mid, mid.high)

        let high = AudioCaptureSignal.analyze(
            samples: toneMixture([3_500, 4_200, 5_000, 6_000, 7_000]),
            sampleRate: 16_000
        ).bands
        XCTAssertGreaterThan(high.high, high.low)
        XCTAssertGreaterThan(high.high, high.mid)
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

    private func toneMixture(_ frequencies: [Float]) -> [Float] {
        let sampleRate: Float = 16_000
        let amplitude = 0.35 / Float(max(1, frequencies.count))
        return (0..<1_024).map { index in
            frequencies.reduce(Float.zero) { value, frequency in
                value + amplitude * sin(2 * .pi * frequency * Float(index) / sampleRate)
            }
        }
    }
}
