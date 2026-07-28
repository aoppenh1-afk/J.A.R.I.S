import XCTest
@testable import JarvisCore

private enum RoutingStubError: Error {
    case failed
}

private actor CountingRecognizer: SpeechRecognizing {
    private let provider: SpeechProvider
    private let shouldFail: Bool
    private(set) var prepareCount = 0
    private(set) var transcribeCount = 0

    init(provider: SpeechProvider, shouldFail: Bool = false) {
        self.provider = provider
        self.shouldFail = shouldFail
    }

    func prepare() throws {
        prepareCount += 1
        if shouldFail { throw RoutingStubError.failed }
    }

    func transcribe(samples: [Float]) throws -> SpeechTranscript {
        transcribeCount += 1
        if shouldFail { throw RoutingStubError.failed }
        return SpeechTranscript(
            text: provider.rawValue,
            audioDuration: .seconds(1),
            inferenceDuration: .milliseconds(1),
            provider: provider
        )
    }

    func counts() -> (prepare: Int, transcribe: Int) {
        (prepareCount, transcribeCount)
    }
}

final class SpeechRouterTests: XCTestCase {
    func testLocalModeNeverInvokesCloudProvider() async throws {
        let local = CountingRecognizer(provider: .local)
        let cloud = CountingRecognizer(provider: .deepgram)
        let router = RoutedSpeechRecognizer(
            mode: .local,
            allowCloudFallback: false,
            local: local,
            cloud: cloud
        )

        try await router.prepare()
        let result = try await router.transcribe(samples: [0.1])
        let cloudCounts = await cloud.counts()

        XCTAssertEqual(result.provider, .local)
        XCTAssertEqual(cloudCounts.prepare, 0)
        XCTAssertEqual(cloudCounts.transcribe, 0)
    }

    func testAutoModeFallsBackOnlyWithExplicitConsent() async throws {
        let local = CountingRecognizer(provider: .local, shouldFail: true)
        let cloud = CountingRecognizer(provider: .deepgram)
        let router = RoutedSpeechRecognizer(
            mode: .auto,
            allowCloudFallback: true,
            local: local,
            cloud: cloud
        )

        let result = try await router.transcribe(samples: [0.1])

        let cloudCounts = await cloud.counts()
        XCTAssertEqual(result.provider, .deepgram)
        XCTAssertEqual(cloudCounts.transcribe, 1)
    }

    func testAutoFallbackReportsReasonAndProviderHealth() async throws {
        let local = CountingRecognizer(provider: .local, shouldFail: true)
        let cloud = CountingRecognizer(provider: .deepgram)
        let router = RoutedSpeechRecognizer(
            mode: .auto,
            allowCloudFallback: true,
            local: local,
            cloud: cloud
        )

        _ = try await router.transcribe(samples: [0.1])
        let status = await router.routingStatus()

        XCTAssertEqual(status.localHealth, .unavailable)
        XCTAssertEqual(status.cloudHealth, .healthy)
        XCTAssertEqual(status.fallbackReason, "Local speech recognition failed")
    }

    func testCloudHealthBecomesUnavailableAfterThreeFailures() async {
        let local = CountingRecognizer(provider: .local)
        let cloud = CountingRecognizer(provider: .deepgram, shouldFail: true)
        let router = RoutedSpeechRecognizer(
            mode: .cloud,
            allowCloudFallback: false,
            local: local,
            cloud: cloud
        )

        for _ in 0..<3 {
            _ = try? await router.transcribe(samples: [0.1])
        }
        let status = await router.routingStatus()
        XCTAssertEqual(status.cloudHealth, .unavailable)
    }

    func testCloudModeWithoutProviderFailsExplicitly() async {
        let local = CountingRecognizer(provider: .local)
        let router = RoutedSpeechRecognizer(
            mode: .cloud,
            allowCloudFallback: false,
            local: local,
            cloud: nil
        )

        do {
            _ = try await router.transcribe(samples: [0.1])
            XCTFail("Expected missing cloud provider")
        } catch {
            XCTAssertEqual(error as? DeepgramSpeechError, .missingCloudProvider)
            let localCounts = await local.counts()
            XCTAssertEqual(localCounts.transcribe, 0)
        }
    }

    func testAutoModeDoesNotFallbackWithoutConsent() async {
        let local = CountingRecognizer(provider: .local, shouldFail: true)
        let cloud = CountingRecognizer(provider: .deepgram)
        let router = RoutedSpeechRecognizer(
            mode: .auto,
            allowCloudFallback: false,
            local: local,
            cloud: cloud
        )

        do {
            _ = try await router.transcribe(samples: [0.1])
            XCTFail("Expected local failure")
        } catch {
            let cloudCounts = await cloud.counts()
            XCTAssertEqual(cloudCounts.transcribe, 0)
        }
    }
}
