import XCTest
@testable import JarvisCore

final class AudioCaptureLifecycleTests: XCTestCase {
    func testIdleCaptureDoesNotAllocateAudioEngine() {
        let capture = AudioCaptureService()

        XCTAssertFalse(capture.isHoldingAudioEngine)
        capture.cancel()
        XCTAssertFalse(capture.isHoldingAudioEngine)
    }

    @MainActor
    func testIdleSpeechDoesNotAllocateSynthesizer() {
        let synthesizer = MacSpeechSynthesizer()

        XCTAssertFalse(synthesizer.isHoldingSpeechSynthesizer)
        synthesizer.stop(contextID: nil)
        XCTAssertFalse(synthesizer.isHoldingSpeechSynthesizer)
    }
}
