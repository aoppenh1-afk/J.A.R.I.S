import XCTest
@testable import JarvisCore

final class AudioInputFormatTests: XCTestCase {
    func testAcceptsUsableInputFormat() throws {
        XCTAssertNoThrow(try AudioInputFormatValidator.validate(sampleRate: 48_000, channels: 2))
    }

    func testRejectsZeroChannelInputFormat() {
        XCTAssertThrowsError(try AudioInputFormatValidator.validate(sampleRate: 48_000, channels: 0)) { error in
            guard case AudioCaptureError.invalidSourceFormat(let sampleRate, let channels) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(sampleRate, 48_000)
            XCTAssertEqual(channels, 0)
        }
    }

    func testRejectsZeroAndNonFiniteSampleRates() {
        XCTAssertThrowsError(try AudioInputFormatValidator.validate(sampleRate: 0, channels: 1))
        XCTAssertThrowsError(try AudioInputFormatValidator.validate(sampleRate: .nan, channels: 1))
    }
}
