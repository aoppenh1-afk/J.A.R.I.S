import Foundation
import ParakeetTDT

public actor ParakeetRecognizer: SpeechRecognizing {
    private let modelURL: URL
    private let selectedComputeUnits: ParakeetComputeUnits
    private let silenceRMSThreshold: Double
    private var transcriber: ParakeetTranscriber?

    public init(
        modelURL: URL,
        computeUnits: String = "ane",
        silenceRMSThreshold: Double = AppConfig.CaptureProfile.normal.silenceRMSThreshold
    ) {
        self.modelURL = modelURL
        self.selectedComputeUnits = ParakeetComputeUnits(rawValue: computeUnits) ?? .ane
        self.silenceRMSThreshold = silenceRMSThreshold
    }

    public func prepare() throws {
        if transcriber == nil {
            try ParakeetModelCacheValidator.validate(at: modelURL)
            transcriber = try ParakeetTranscriber(
                modelsRoot: modelURL,
                computeUnits: selectedComputeUnits
            )
        }
    }

    public func transcribe(samples: [Float]) throws -> SpeechTranscript {
        guard !AudioSignal.isLikelySilent(samples, threshold: silenceRMSThreshold) else {
            return SpeechTranscript(
                text: "",
                audioDuration: .milliseconds(Int64(Double(samples.count) / 16)),
                inferenceDuration: .zero
            )
        }

        try prepare()
        guard let transcriber else {
            throw ParakeetRecognizerError.notPrepared
        }
        let result = try transcriber.transcribe(samples: samples)
        return SpeechTranscript(
            text: result.text,
            audioDuration: .milliseconds(Int64(result.audioDurationSeconds * 1_000)),
            inferenceDuration: .milliseconds(Int64(result.inferenceDurationSeconds * 1_000))
        )
    }
}

public enum ParakeetRecognizerError: Error {
    case notPrepared
}
