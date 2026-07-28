import Foundation

public actor RoutedSpeechRecognizer: SpeechRecognizing {
    private let local: any SpeechRecognizing
    private let cloud: (any SpeechRecognizing)?
    private var mode: AppConfig.SpeechMode
    private var allowCloudFallback: Bool
    private var localHealth: ProviderHealth = .unknown
    private var cloudHealth: ProviderHealth = .unknown
    private var cloudFailureCount = 0
    private var fallbackReason: String?

    public init(
        mode: AppConfig.SpeechMode,
        allowCloudFallback: Bool,
        local: any SpeechRecognizing,
        cloud: (any SpeechRecognizing)?
    ) {
        self.mode = mode
        self.allowCloudFallback = allowCloudFallback
        self.local = local
        self.cloud = cloud
    }

    public func update(mode: AppConfig.SpeechMode, allowCloudFallback: Bool) {
        self.mode = mode
        self.allowCloudFallback = allowCloudFallback
    }

    public func prepare() async throws {
        switch mode {
        case .local:
            try await local.prepare()
        case .cloud:
            guard let cloud else { throw DeepgramSpeechError.missingCloudProvider }
            try await cloud.prepare()
        case .auto:
            do {
                try await local.prepare()
            } catch {
                guard allowCloudFallback else { throw error }
                guard let cloud else { throw DeepgramSpeechError.missingCloudProvider }
                try await cloud.prepare()
                return
            }
            if allowCloudFallback, let cloud { try await cloud.prepare() }
        }
    }

    public func transcribe(samples: [Float]) async throws -> SpeechTranscript {
        fallbackReason = nil
        switch mode {
        case .local:
            do {
                let transcript = try await local.transcribe(samples: samples)
                localHealth = .healthy
                return transcript
            } catch {
                localHealth = .unavailable
                throw error
            }
        case .cloud:
            guard let cloud else {
                recordCloudFailure()
                throw DeepgramSpeechError.missingCloudProvider
            }
            do {
                let transcript = try await cloud.transcribe(samples: samples)
                recordCloudSuccess()
                return transcript
            } catch {
                recordCloudFailure()
                throw error
            }
        case .auto:
            do {
                let transcript = try await local.transcribe(samples: samples)
                localHealth = .healthy
                return transcript
            } catch {
                localHealth = .unavailable
                guard allowCloudFallback else { throw error }
                fallbackReason = "Local speech recognition failed"
                guard let cloud else {
                    recordCloudFailure()
                    throw DeepgramSpeechError.missingCloudProvider
                }
                do {
                    let transcript = try await cloud.transcribe(samples: samples)
                    recordCloudSuccess()
                    return transcript
                } catch {
                    recordCloudFailure()
                    throw error
                }
            }
        }
    }

    public func routingStatus() async -> SpeechRoutingStatus {
        SpeechRoutingStatus(
            localHealth: localHealth,
            cloudHealth: cloudHealth,
            fallbackReason: fallbackReason
        )
    }

    private func recordCloudSuccess() {
        cloudFailureCount = 0
        cloudHealth = .healthy
    }

    private func recordCloudFailure() {
        cloudFailureCount = min(cloudFailureCount + 1, 3)
        cloudHealth = cloudFailureCount >= 3 ? .unavailable : .degraded
    }
}

@MainActor
public final class RoutedSpeechSynthesizer: SpeechSynthesizing {
    private let local: any SpeechSynthesizing
    private let cloud: (any SpeechSynthesizing)?
    private var mode: AppConfig.SpeechMode
    private var allowCloudFallback: Bool

    public init(
        mode: AppConfig.SpeechMode,
        allowCloudFallback: Bool,
        local: any SpeechSynthesizing,
        cloud: (any SpeechSynthesizing)?
    ) {
        self.mode = mode
        self.allowCloudFallback = allowCloudFallback
        self.local = local
        self.cloud = cloud
    }

    public func update(mode: AppConfig.SpeechMode, allowCloudFallback: Bool) {
        self.mode = mode
        self.allowCloudFallback = allowCloudFallback
    }

    public func speak(_ text: String, contextID: UUID) async throws {
        switch mode {
        case .local:
            try await local.speak(text, contextID: contextID)
        case .cloud:
            guard let cloud else { throw DeepgramSpeechError.missingCloudProvider }
            try await cloud.speak(text, contextID: contextID)
        case .auto:
            do {
                try await local.speak(text, contextID: contextID)
            } catch {
                guard allowCloudFallback else { throw error }
                guard let cloud else { throw DeepgramSpeechError.missingCloudProvider }
                try await cloud.speak(text, contextID: contextID)
            }
        }
    }

    public func stop(contextID: UUID?) {
        local.stop(contextID: contextID)
        cloud?.stop(contextID: contextID)
    }
}
