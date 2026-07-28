import Foundation

public enum SpeechProvider: String, Sendable, Codable, Equatable {
    case local
    case deepgram
}

public enum ProviderHealth: String, Sendable, Codable, Equatable {
    case unknown
    case healthy
    case degraded
    case unavailable
}

public struct SpeechRoutingStatus: Sendable, Equatable {
    public var localHealth: ProviderHealth
    public var cloudHealth: ProviderHealth
    public var fallbackReason: String?

    public init(
        localHealth: ProviderHealth = .unknown,
        cloudHealth: ProviderHealth = .unknown,
        fallbackReason: String? = nil
    ) {
        self.localHealth = localHealth
        self.cloudHealth = cloudHealth
        self.fallbackReason = fallbackReason
    }
}

public struct SpeechTranscript: Sendable, Equatable {
    public let text: String
    public let audioDuration: Duration
    public let inferenceDuration: Duration
    public let provider: SpeechProvider

    public init(
        text: String,
        audioDuration: Duration,
        inferenceDuration: Duration,
        provider: SpeechProvider = .local
    ) {
        self.text = text
        self.audioDuration = audioDuration
        self.inferenceDuration = inferenceDuration
        self.provider = provider
    }
}

public protocol SpeechRecognizing: Sendable {
    func prepare() async throws
    func transcribe(samples: [Float]) async throws -> SpeechTranscript
    func routingStatus() async -> SpeechRoutingStatus
}

public extension SpeechRecognizing {
    func routingStatus() async -> SpeechRoutingStatus { SpeechRoutingStatus() }
}

@MainActor
public protocol SpeechSynthesizing: AnyObject, Sendable {
    func speak(_ text: String, contextID: UUID) async throws
    func stop(contextID: UUID?)
}
