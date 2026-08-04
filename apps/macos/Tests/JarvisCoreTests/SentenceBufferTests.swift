import XCTest
@testable import JarvisCore

final class SentenceBufferTests: XCTestCase {
    func testEmitsCompleteSentencesAndFlushesRemainder() {
        var buffer = SentenceBuffer()

        XCTAssertEqual(buffer.append("Hello there. How"), ["Hello there."])
        XCTAssertEqual(buffer.append(" are you? Fine"), ["How are you?"])
        XCTAssertEqual(buffer.flush(), "Fine")
        XCTAssertNil(buffer.flush())
    }

    func testLineBreakDoesNotCreateASpeechBoundary() {
        var buffer = SentenceBuffer()

        XCTAssertEqual(buffer.append("First line\nsecond line."), ["First line second line."])
    }
}
