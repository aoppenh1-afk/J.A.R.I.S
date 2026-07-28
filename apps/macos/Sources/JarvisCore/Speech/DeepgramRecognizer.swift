import Foundation

public actor DeepgramRecognizer: SpeechRecognizing {
    private let apiKey: String
    private let model: String
    private let language: String
    private let session: URLSession
    private let endpoint: URL
    private let silenceRMSThreshold: Double

    public init(
        apiKey: String,
        model: String = "nova-3",
        language: String = "en",
        endpoint: URL = URL(string: "https://api.deepgram.com/v1/listen")!,
        session: URLSession = .shared,
        silenceRMSThreshold: Double = AppConfig.CaptureProfile.normal.silenceRMSThreshold
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.endpoint = endpoint
        self.session = session
        self.silenceRMSThreshold = silenceRMSThreshold
    }

    public func prepare() throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepgramSpeechError.missingAPIKey
        }
    }

    public func transcribe(samples: [Float]) async throws -> SpeechTranscript {
        try prepare()
        guard !AudioSignal.isLikelySilent(samples, threshold: silenceRMSThreshold) else {
            return SpeechTranscript(
                text: "",
                audioDuration: .milliseconds(Int64(Double(samples.count) / 16)),
                inferenceDuration: .zero,
                provider: .deepgram
            )
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "smart_format", value: "true"),
        ]
        guard let url = components?.url else { throw DeepgramSpeechError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = WAVEncoder.encodeMono16kPCM16(samples: samples)

        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await session.data(for: request)
        let inferenceDuration = start.duration(to: clock.now)
        guard let response = response as? HTTPURLResponse else {
            throw DeepgramSpeechError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw DeepgramSpeechError.httpStatus(response.statusCode)
        }

        let payload: DeepgramTranscriptionResponse
        do {
            payload = try JSONDecoder().decode(DeepgramTranscriptionResponse.self, from: data)
        } catch {
            throw DeepgramSpeechError.invalidResponse
        }
        let text = payload.results.channels.first?.alternatives.first?.transcript ?? ""
        return SpeechTranscript(
            text: text,
            audioDuration: .milliseconds(Int64(Double(samples.count) / 16)),
            inferenceDuration: inferenceDuration,
            provider: .deepgram
        )
    }
}

private struct DeepgramTranscriptionResponse: Decodable {
    let results: Results

    struct Results: Decodable {
        let channels: [Channel]
    }

    struct Channel: Decodable {
        let alternatives: [Alternative]
    }

    struct Alternative: Decodable {
        let transcript: String
    }
}

public enum DeepgramSpeechError: Error, Equatable, CustomStringConvertible {
    case audioPlaybackFailed
    case httpStatus(Int)
    case invalidEndpoint
    case invalidResponse
    case missingAPIKey
    case missingCloudProvider

    public var description: String {
        switch self {
        case .audioPlaybackFailed:
            return "Deepgram returned audio that macOS could not play."
        case .httpStatus(let status):
            return "Deepgram returned HTTP status \(status)."
        case .invalidEndpoint:
            return "The Deepgram endpoint is invalid."
        case .invalidResponse:
            return "Deepgram returned an invalid response."
        case .missingAPIKey:
            return "A Deepgram API key is required for cloud speech."
        case .missingCloudProvider:
            return "Cloud speech is selected but no Deepgram provider is configured."
        }
    }
}
