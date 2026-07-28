import AVFoundation
import Foundation

enum DeepgramTTSMessage: Sendable {
    case data(Data)
    case text(String)
}

@MainActor
protocol DeepgramTTSStreamingTransport: AnyObject {
    func resume()
    func send(text: String) async throws
    func receive() async throws -> DeepgramTTSMessage
    func cancel()
}

@MainActor
private final class URLSessionDeepgramTTSStreamingTransport: DeepgramTTSStreamingTransport {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest, session: URLSession) {
        task = session.webSocketTask(with: request)
    }

    func resume() {
        task.resume()
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> DeepgramTTSMessage {
        switch try await task.receive() {
        case let .data(data):
            return .data(data)
        case let .string(text):
            return .text(text)
        @unknown default:
            throw DeepgramSpeechError.invalidResponse
        }
    }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

@MainActor
public final class DeepgramSynthesizer: SpeechSynthesizing {
    typealias TransportFactory = @MainActor (URLRequest) -> any DeepgramTTSStreamingTransport

    private let apiKey: String
    private let model: String
    private let endpoint: URL
    private let transportFactory: TransportFactory
    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    private var activeContextID: UUID?
    private var transport: (any DeepgramTTSStreamingTransport)?
    private var receiveTask: Task<Void, Never>?
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var pendingBuffers = 0
    private var playbackStarted = false
    private var sentFlushCount = 0
    private var receivedFlushCount = 0
    private var isFinishing = false
    private var finishContinuation: CheckedContinuation<Void, Error>?
    private var streamError: Error?

    public init(
        apiKey: String,
        model: String = "aura-2-thalia-en",
        endpoint: URL = URL(string: "https://api.deepgram.com/v1/speak")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        transportFactory = { request in
            URLSessionDeepgramTTSStreamingTransport(request: request, session: session)
        }
    }

    init(
        apiKey: String,
        model: String = "aura-2-thalia-en",
        endpoint: URL = URL(string: "https://api.deepgram.com/v1/speak")!,
        transportFactory: @escaping TransportFactory
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.transportFactory = transportFactory
    }

    public func speak(_ text: String, contextID: UUID) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepgramSpeechError.missingAPIKey
        }

        if activeContextID != contextID {
            stop(contextID: nil)
            try startStream(contextID: contextID)
        }

        guard let transport else { throw DeepgramSpeechError.invalidResponse }
        try await transport.send(text: Self.speakMessage(text))
        try await transport.send(text: Self.flushMessage)
        sentFlushCount += 1
    }

    public func finish(contextID: UUID) async throws {
        guard activeContextID == contextID else { return }
        if let streamError { throw streamError }
        guard sentFlushCount > 0 else {
            resetStream()
            return
        }

        isFinishing = true
        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
            finishIfDrained()
        }
    }

    public func stop(contextID: UUID?) {
        guard contextID == nil || contextID == activeContextID else { return }
        finishContinuation?.resume()
        finishContinuation = nil
        resetStream()
    }

    static func streamingURL(endpoint: URL, model: String) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw DeepgramSpeechError.invalidEndpoint
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: throw DeepgramSpeechError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "24000"),
            URLQueryItem(name: "container", value: "none"),
        ]
        guard let url = components.url else { throw DeepgramSpeechError.invalidEndpoint }
        return url
    }

    private func startStream(contextID: UUID) throws {
        let url = try Self.streamingURL(endpoint: endpoint, model: model)
        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let transport = transportFactory(request)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
        try engine.start()

        activeContextID = contextID
        self.transport = transport
        audioEngine = engine
        playerNode = player
        pendingBuffers = 0
        playbackStarted = false
        sentFlushCount = 0
        receivedFlushCount = 0
        isFinishing = false
        streamError = nil
        transport.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveMessages(contextID: contextID, transport: transport)
        }
    }

    private func receiveMessages(
        contextID: UUID,
        transport: any DeepgramTTSStreamingTransport
    ) async {
        do {
            while activeContextID == contextID, !Task.isCancelled {
                switch try await transport.receive() {
                case let .data(data):
                    scheduleAudio(data, contextID: contextID)
                case let .text(text):
                    handleControlMessage(text, contextID: contextID)
                }
            }
        } catch {
            guard activeContextID == contextID, !Task.isCancelled else { return }
            streamError = error
            finishContinuation?.resume(throwing: error)
            finishContinuation = nil
            transport.cancel()
            self.transport = nil
            playerNode?.stop()
            playerNode = nil
            audioEngine?.stop()
            audioEngine = nil
            pendingBuffers = 0
            playbackStarted = false
        }
    }

    private func scheduleAudio(_ data: Data, contextID: UUID) {
        guard activeContextID == contextID,
              data.count >= MemoryLayout<Int16>.size,
              let playerNode,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: audioFormat,
                  frameCapacity: AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
              ),
              let destination = buffer.int16ChannelData?.pointee else { return }

        let frameCount = data.count / MemoryLayout<Int16>.size
        data.withUnsafeBytes { source in
            guard let source = source.baseAddress else { return }
            destination.update(from: source.assumingMemoryBound(to: Int16.self), count: frameCount)
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        pendingBuffers += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.didPlayBuffer(contextID: contextID)
            }
        }
        startPlaybackIfReady()
    }

    private func handleControlMessage(_ text: String, contextID: UUID) {
        guard activeContextID == contextID,
              let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = (message["type"] as? String)?.lowercased() else { return }
        guard type == "flushed" else { return }
        receivedFlushCount += 1
        finishIfDrained()
    }

    private func startPlaybackIfReady() {
        guard !playbackStarted,
              pendingBuffers > 0,
              let playerNode else { return }
        playbackStarted = true
        playerNode.play()
    }

    private func didPlayBuffer(contextID: UUID) {
        guard activeContextID == contextID else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        finishIfDrained()
    }

    private func finishIfDrained() {
        guard isFinishing,
              receivedFlushCount >= sentFlushCount,
              pendingBuffers == 0 else { return }
        finishContinuation?.resume()
        finishContinuation = nil
        resetStream()
    }

    private func resetStream() {
        receiveTask?.cancel()
        receiveTask = nil
        transport?.cancel()
        transport = nil
        playerNode?.stop()
        playerNode = nil
        audioEngine?.stop()
        audioEngine = nil
        activeContextID = nil
        pendingBuffers = 0
        playbackStarted = false
        sentFlushCount = 0
        receivedFlushCount = 0
        isFinishing = false
        streamError = nil
    }

    private static func speakMessage(_ text: String) -> String {
        let data = try! JSONEncoder().encode(["type": "Speak", "text": text])
        return String(decoding: data, as: UTF8.self)
    }

    private static let flushMessage = #"{"type":"Flush"}"#
}
