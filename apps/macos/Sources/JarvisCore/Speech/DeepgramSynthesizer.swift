import AVFoundation
import Foundation

@MainActor
public final class DeepgramSynthesizer: NSObject, SpeechSynthesizing, @preconcurrency AVAudioPlayerDelegate {
    private let apiKey: String
    private let model: String
    private let session: URLSession
    private let endpoint: URL
    private var activeContextID: UUID?
    private var player: AVAudioPlayer?
    private var completion: CheckedContinuation<Void, Never>?

    public init(
        apiKey: String,
        model: String = "aura-2-thalia-en",
        endpoint: URL = URL(string: "https://api.deepgram.com/v1/speak")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.session = session
    }

    public func speak(_ text: String, contextID: UUID) async throws {
        stop(contextID: nil)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepgramSpeechError.missingAPIKey
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "container", value: "wav"),
            URLQueryItem(name: "sample_rate", value: "24000"),
        ]
        guard let url = components?.url else { throw DeepgramSpeechError.invalidEndpoint }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": text])
        activeContextID = contextID

        let (data, response) = try await session.data(for: request)
        guard activeContextID == contextID, !Task.isCancelled else { return }
        guard let response = response as? HTTPURLResponse else {
            throw DeepgramSpeechError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw DeepgramSpeechError.httpStatus(response.statusCode)
        }

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            throw DeepgramSpeechError.audioPlaybackFailed
        }
        self.player = player
        player.delegate = self
        player.prepareToPlay()

        await withCheckedContinuation { continuation in
            completion = continuation
            if !player.play() { finish() }
        }
    }

    public func stop(contextID: UUID?) {
        guard contextID == nil || contextID == activeContextID else { return }
        player?.stop()
        finish()
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish()
    }

    private func finish() {
        completion?.resume()
        completion = nil
        player = nil
        activeContextID = nil
    }
}
