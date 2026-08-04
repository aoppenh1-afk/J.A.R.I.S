import XCTest
@testable import JarvisCore

final class HermesResponsePresentationTests: XCTestCase {
    func testParsesSourcesAndCapsFollowUpsAtThree() {
        let response = """
        Updated the streaming lifecycle.
        <jarvis_ui>{"follow_up_prompts":["Run the tests","Show the diff","Explain the fix","Duplicate"],"sources":[{"path":"apps/macos/Sources/JarvisCore/VoicePipeline.swift","line":184,"label":"Streaming fix"}]}</jarvis_ui>
        """

        let presentation = HermesResponsePresentationParser.parse(response)

        XCTAssertEqual(presentation.text, "Updated the streaming lifecycle.")
        XCTAssertEqual(presentation.followUpPrompts, ["Run the tests", "Show the diff", "Explain the fix"])
        XCTAssertEqual(presentation.sources, [
            ResponseSource(
                path: "apps/macos/Sources/JarvisCore/VoicePipeline.swift",
                line: 184,
                label: "Streaming fix"
            )
        ])
    }

    func testStreamFilterHidesMetadataAcrossDeltaBoundaries() {
        var filter = HermesResponseStreamFilter()

        let first = filter.append("Fixed the issue.\n<jar")
        let second = filter.append("vis_ui>{\"follow_up_prompts\":[\"Explain it\"],")
        let third = filter.append("\"sources\":[]}</jarvis_ui>")
        let tail = filter.finish()

        XCTAssertEqual(first + second + third + tail, "Fixed the issue.\n")
    }

    func testMalformedMetadataIsNeverShownAsVisibleResponse() {
        let response = "Done.\n<jarvis_ui>{not-json}</jarvis_ui>"

        let presentation = HermesResponsePresentationParser.parse(response)

        XCTAssertEqual(presentation.text, "Done.")
        XCTAssertTrue(presentation.sources.isEmpty)
        XCTAssertTrue(presentation.followUpPrompts.isEmpty)
    }
}
