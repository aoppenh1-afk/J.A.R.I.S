import Foundation
import XCTest
@testable import JarvisCore

private final class DeepgramTTSURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let result = try Self.handler?(request) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func ttsRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { throw URLError(.zeroByteResource) }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
        if count == 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return data
}

@MainActor
final class DeepgramSynthesizerTests: XCTestCase {
    override func tearDown() {
        DeepgramTTSURLProtocol.handler = nil
        super.tearDown()
    }

    func testBuildsAuraRequestAndAcceptsWAVAudio() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramTTSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepgramTTSURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertTrue(request.url?.absoluteString.contains("model=aura-2-thalia-en") == true)
            XCTAssertTrue(request.url?.absoluteString.contains("encoding=linear16") == true)
            XCTAssertTrue(request.url?.absoluteString.contains("container=wav") == true)
            XCTAssertTrue(request.url?.absoluteString.contains("sample_rate=24000") == true)

            let body = try ttsRequestBody(request)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload["text"], "Hello from Jarvis.")
            let audio = WAVEncoder.encodeMono16kPCM16(samples: [Float](repeating: 0, count: 160))
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                audio
            )
        }

        let synthesizer = DeepgramSynthesizer(apiKey: "secret", session: session)
        try await synthesizer.speak("Hello from Jarvis.", contextID: UUID())
    }

    func testMapsHTTPFailure() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramTTSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepgramTTSURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let synthesizer = DeepgramSynthesizer(apiKey: "secret", session: session)
        do {
            try await synthesizer.speak("Hello", contextID: UUID())
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertEqual(error as? DeepgramSpeechError, .httpStatus(503))
        }
    }

    func testPropagatesTimeoutWithoutRetrying() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramTTSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestCount = 0
        DeepgramTTSURLProtocol.handler = { _ in
            requestCount += 1
            throw URLError(.timedOut)
        }

        let synthesizer = DeepgramSynthesizer(apiKey: "secret", session: session)
        do {
            try await synthesizer.speak("Hello", contextID: UUID())
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testMissingKeyFailsBeforeNetworkRequest() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramTTSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepgramTTSURLProtocol.handler = { _ in
            XCTFail("Missing key must fail before a request")
            throw URLError(.dataNotAllowed)
        }

        let synthesizer = DeepgramSynthesizer(apiKey: "", session: session)
        do {
            try await synthesizer.speak("Hello", contextID: UUID())
            XCTFail("Expected missing key")
        } catch {
            XCTAssertEqual(error as? DeepgramSpeechError, .missingAPIKey)
        }
    }

    func testRejectsMalformedAudio() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramTTSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepgramTTSURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("not-audio".utf8)
            )
        }

        let synthesizer = DeepgramSynthesizer(apiKey: "secret", session: session)
        do {
            try await synthesizer.speak("Hello", contextID: UUID())
            XCTFail("Expected malformed audio failure")
        } catch {
            XCTAssertEqual(error as? DeepgramSpeechError, .audioPlaybackFailed)
        }
    }

    func testStopCancelsMatchingPlaybackContext() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramTTSURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepgramTTSURLProtocol.handler = { request in
            let audio = WAVEncoder.encodeMono16kPCM16(samples: [Float](repeating: 0.02, count: 16_000))
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                audio
            )
        }

        let synthesizer = DeepgramSynthesizer(apiKey: "secret", session: session)
        let contextID = UUID()
        let task = Task { try await synthesizer.speak("Long response", contextID: contextID) }
        await Task.yield()
        synthesizer.stop(contextID: contextID)
        try await task.value
    }
}
