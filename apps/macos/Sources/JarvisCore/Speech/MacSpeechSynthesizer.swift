import AVFoundation
import Foundation

public enum MacSpeechSynthesizerError: Error, Equatable {
    case voiceNotFound(String)
}

public enum MacSpeechVoice {
    public static let jamiePremiumIdentifier = "com.apple.voice.premium.en-GB.Malcolm"
}

@MainActor
public final class MacSpeechSynthesizer: NSObject, SpeechSynthesizing, @preconcurrency AVSpeechSynthesizerDelegate {
    private var synthesizer: AVSpeechSynthesizer?
    private let voiceIdentifier: String?
    private let rate: Float
    private let pitchMultiplier: Float
    private var activeContextID: UUID?
    private var completion: CheckedContinuation<Void, Never>?

    var isHoldingSpeechSynthesizer: Bool { synthesizer != nil }

    public init(
        voiceIdentifier: String? = MacSpeechVoice.jamiePremiumIdentifier,
        rate: Float = AVSpeechUtteranceDefaultSpeechRate,
        pitchMultiplier: Float = 1
    ) {
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        self.pitchMultiplier = pitchMultiplier
        super.init()
    }

    public func speak(_ text: String, contextID: UUID) async throws {
        stop(contextID: nil)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        if let voiceIdentifier {
            if let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                utterance.voice = voice
            } else if voiceIdentifier != MacSpeechVoice.jamiePremiumIdentifier {
                throw MacSpeechSynthesizerError.voiceNotFound(voiceIdentifier)
            }
        }
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        self.synthesizer = synthesizer
        activeContextID = contextID
        utterance.rate = rate
        utterance.pitchMultiplier = pitchMultiplier
        await withCheckedContinuation { continuation in
            completion = continuation
            synthesizer.speak(utterance)
        }
    }

    public func stop(contextID: UUID?) {
        guard contextID == nil || contextID == activeContextID else { return }
        if let synthesizer, synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finish()
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finish()
    }

    public func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finish()
    }

    private func finish() {
        completion?.resume()
        completion = nil
        activeContextID = nil
        synthesizer?.delegate = nil
        synthesizer = nil
    }
}
