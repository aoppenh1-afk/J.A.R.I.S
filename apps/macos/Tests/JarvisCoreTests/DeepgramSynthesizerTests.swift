import Foundation
import XCTest
@testable import JarvisCore

@MainActor
private final class FakeDeepgramTTSStreamingTransport: DeepgramTTSStreamingTransport {
    private(set) var didResume = false
    private(set) var sentMessages: [String] = []
    private var pendingFlushResponses = 0

    func resume() {
        didResume = true
    }

    func send(text: String) async throws {
        sentMessages.append(text)
        if text == #"{"type":"Flush"}"# {
            pendingFlushResponses += 1
        }
    }

    func receive() async throws -> DeepgramTTSMessage {
        while pendingFlushResponses == 0 {
            await Task.yield()
        }
        pendingFlushResponses -= 1
        return .text(#"{"type":"Flushed"}"#)
    }

    func cancel() {}
}

@MainActor
private final class FailingDeepgramTTSStreamingTransport: DeepgramTTSStreamingTransport {
    func resume() {}
    func send(text: String) async throws {}
    func receive() async throws -> DeepgramTTSMessage { throw URLError(.cannotConnectToHost) }
    func cancel() {}
}

@MainActor
final class DeepgramSynthesizerTests: XCTestCase {
    func testBuildsStreamingWebSocketURL() throws {
        let url = try DeepgramSynthesizer.streamingURL(
            endpoint: URL(string: "https://api.deepgram.com/v1/speak")!,
            model: "aura-2-thalia-en"
        )

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "api.deepgram.com")
        XCTAssertEqual(url.path, "/v1/speak")
        XCTAssertTrue(url.absoluteString.contains("model=aura-2-thalia-en"))
        XCTAssertTrue(url.absoluteString.contains("encoding=linear16"))
        XCTAssertTrue(url.absoluteString.contains("sample_rate=24000"))
        XCTAssertTrue(url.absoluteString.contains("container=none"))
        XCTAssertFalse(url.absoluteString.contains("container=wav"))
    }

    func testStreamsSentenceChunksOverOneConnectionAndFlushes() async throws {
        let transport = FakeDeepgramTTSStreamingTransport()
        var authorization: String?
        let synthesizer = DeepgramSynthesizer(
            apiKey: "secret",
            transportFactory: { request in
                authorization = request.value(forHTTPHeaderField: "Authorization")
                return transport
            }
        )
        let contextID = UUID()

        try await synthesizer.speak("First sentence.", contextID: contextID)
        try await synthesizer.speak("Second sentence.", contextID: contextID)
        try await synthesizer.finish(contextID: contextID)

        XCTAssertTrue(transport.didResume)
        XCTAssertEqual(authorization, "Token secret")
        XCTAssertEqual(transport.sentMessages.count, 4)
        XCTAssertTrue(transport.sentMessages[0].contains(#""type":"Speak""#))
        XCTAssertTrue(transport.sentMessages[0].contains(#""text":"First sentence.""#))
        XCTAssertEqual(transport.sentMessages[1], #"{"type":"Flush"}"#)
        XCTAssertTrue(transport.sentMessages[2].contains(#""text":"Second sentence.""#))
        XCTAssertEqual(transport.sentMessages[3], #"{"type":"Flush"}"#)
    }

    func testPropagatesStreamingFailureWhenFinishing() async throws {
        let synthesizer = DeepgramSynthesizer(
            apiKey: "secret",
            transportFactory: { _ in FailingDeepgramTTSStreamingTransport() }
        )
        let contextID = UUID()

        try await synthesizer.speak("Hello", contextID: contextID)
        do {
            try await synthesizer.finish(contextID: contextID)
            XCTFail("Expected streaming failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
    }

    func testMissingKeyFailsBeforeStartingTransport() async {
        let synthesizer = DeepgramSynthesizer(apiKey: "")
        do {
            try await synthesizer.speak("Hello", contextID: UUID())
            XCTFail("Expected missing key")
        } catch {
            XCTAssertEqual(error as? DeepgramSpeechError, .missingAPIKey)
        }
    }
}
