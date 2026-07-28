import Foundation
import XCTest
@testable import JarvisCore

private final class DeepgramURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let result = try Self.handler?(request)
            guard let result else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
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

final class DeepgramRecognizerTests: XCTestCase {
    override func tearDown() {
        DeepgramURLProtocol.handler = nil
        super.tearDown()
    }

    func testUploadsWAVAndDecodesTranscript() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepgramURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
            let body = try requestBody(request)
            XCTAssertEqual(body.prefix(4), Data("RIFF".utf8))
            XCTAssertTrue(request.url?.absoluteString.contains("model=nova-3") == true)
            let data = Data(#"{"results":{"channels":[{"alternatives":[{"transcript":"cloud transcript"}]}]}}"#.utf8)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let recognizer = DeepgramRecognizer(apiKey: "secret", session: session)
        let result = try await recognizer.transcribe(samples: [Float](repeating: 0.1, count: 1_600))

        XCTAssertEqual(result.text, "cloud transcript")
        XCTAssertEqual(result.provider, .deepgram)
    }

    func testMapsHTTPFailure() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepgramURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let recognizer = DeepgramRecognizer(apiKey: "secret", session: session)
        do {
            _ = try await recognizer.transcribe(samples: [Float](repeating: 0.1, count: 1_600))
            XCTFail("Expected HTTP error")
        } catch {
            XCTAssertEqual(error as? DeepgramSpeechError, .httpStatus(429))
        }
    }

    func testRejectsMalformedResponse() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepgramURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("not-json".utf8)
            )
        }

        let recognizer = DeepgramRecognizer(apiKey: "secret", session: session)
        do {
            _ = try await recognizer.transcribe(samples: [Float](repeating: 0.1, count: 1_600))
            XCTFail("Expected invalid response")
        } catch {
            XCTAssertEqual(error as? DeepgramSpeechError, .invalidResponse)
        }
    }

    func testPropagatesTimeoutWithoutRetrying() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestCount = 0
        DeepgramURLProtocol.handler = { _ in
            requestCount += 1
            throw URLError(.timedOut)
        }

        let recognizer = DeepgramRecognizer(apiKey: "secret", session: session)
        do {
            _ = try await recognizer.transcribe(samples: [Float](repeating: 0.1, count: 1_600))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testMissingKeyFailsBeforeNetworkRequest() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepgramURLProtocol.handler = { _ in
            XCTFail("Missing key must fail before a request")
            throw URLError(.dataNotAllowed)
        }

        let recognizer = DeepgramRecognizer(apiKey: "", session: session)
        do {
            _ = try await recognizer.transcribe(samples: [0.1])
            XCTFail("Expected missing key")
        } catch {
            XCTAssertEqual(error as? DeepgramSpeechError, .missingAPIKey)
        }
    }

    func testRejectsSilenceWithoutNetworkRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepgramURLProtocol.self]
        let session = URLSession(configuration: configuration)
        DeepgramURLProtocol.handler = { _ in
            XCTFail("Silence must not reach Deepgram")
            throw URLError(.dataNotAllowed)
        }

        let recognizer = DeepgramRecognizer(apiKey: "secret", session: session)
        let result = try await recognizer.transcribe(samples: [Float](repeating: 0, count: 1_600))

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.provider, .deepgram)
    }
}
