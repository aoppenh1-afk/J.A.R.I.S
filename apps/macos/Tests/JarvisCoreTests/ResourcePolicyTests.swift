import Foundation
import XCTest
@testable import JarvisCore

final class ResourcePolicyTests: XCTestCase {
    func testAutomaticAnimationRespondsToLowPowerAndActivity() {
        XCTAssertEqual(AnimationQuality.automatic.framesPerSecond(isActive: true, lowPowerMode: false, reduceMotion: false), 30)
        XCTAssertEqual(AnimationQuality.automatic.framesPerSecond(isActive: true, lowPowerMode: true, reduceMotion: false), 15)
        XCTAssertEqual(AnimationQuality.automatic.framesPerSecond(isActive: false, lowPowerMode: true, reduceMotion: false), 5)
        XCTAssertEqual(AnimationQuality.automatic.framesPerSecond(isActive: false, lowPowerMode: false, reduceMotion: false), 10)
    }

    func testReduceMotionStopsEveryAnimationQuality() {
        for quality in AnimationQuality.allCases {
            XCTAssertEqual(quality.framesPerSecond(isActive: true, lowPowerMode: false, reduceMotion: true), 0)
        }
    }

    func testExplicitAnimationChoicesOverridePowerMode() {
        XCTAssertEqual(AnimationQuality.smooth.framesPerSecond(isActive: true, lowPowerMode: true, reduceMotion: false), 60)
        XCTAssertEqual(AnimationQuality.energySaving.framesPerSecond(isActive: true, lowPowerMode: false, reduceMotion: false), 15)
    }

    func testExistingPreferencesDefaultToAutomaticAnimation() throws {
        let encoded = try JSONEncoder().encode(AppPreferences(animationQuality: .smooth))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "animationQuality")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: legacy).animationQuality, .automatic)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: encoded).animationQuality, .smooth)
    }

    func testHotkeyChangesPreserveRuntimeButSpeechChangesRebuildIt() {
        let original = AppConfig()
        var edited = original
        edited.hotkey = HotkeyConfiguration.allCases.first { $0 != original.hotkey }!
        XCTAssertFalse(edited.requiresRuntimeRebuild(comparedTo: original))
        edited.captureProfile = .noisy
        XCTAssertTrue(edited.requiresRuntimeRebuild(comparedTo: original))
        edited = original
        edited.hermesBaseURL = URL(string: "http://localhost:9000")!
        XCTAssertTrue(edited.requiresRuntimeRebuild(comparedTo: original))
    }

    func testRecordingCapsSamplesAndReleasesThemAfterStop() {
        var recording = AudioRecordingBuffer(maximumSamples: 5)
        let first: [Float] = [1, 2, 3]
        XCTAssertFalse(first.withUnsafeBufferPointer { recording.append($0) })
        let second: [Float] = [4, 5, 6, 7]
        XCTAssertTrue(second.withUnsafeBufferPointer { recording.append($0) })
        XCTAssertEqual(recording.samples, [1, 2, 3, 4, 5])
        XCTAssertTrue(first.withUnsafeBufferPointer { recording.append($0) })
        XCTAssertEqual(recording.takeSamples(), [1, 2, 3, 4, 5])
        XCTAssertTrue(recording.samples.isEmpty)
    }
}
