import AVFoundation
import Foundation

public protocol AudioCapturing: AnyObject {
    func start() throws
    func stop() -> [Float]
    func cancel()
}

public enum AudioCaptureError: Error, LocalizedError {
    case inputDeviceUnavailable
    case invalidSourceFormat(sampleRate: Double, channels: UInt32)
    case invalidTargetFormat
    case converterCreationFailed
    case outputBufferCreationFailed
    case conversionFailed(Error?)

    public var errorDescription: String? {
        switch self {
        case .inputDeviceUnavailable:
            return "No microphone input device is available."
        case .invalidSourceFormat(let sampleRate, let channels):
            return "The microphone reported an invalid format (\(Int(sampleRate)) Hz, \(channels) channels)."
        case .invalidTargetFormat:
            return "Unable to create the required 16 kHz mono audio format."
        case .converterCreationFailed:
            return "Unable to convert audio from the selected microphone."
        case .outputBufferCreationFailed:
            return "Unable to allocate an audio conversion buffer."
        case .conversionFailed:
            return "The microphone audio conversion failed."
        }
    }
}

public enum AudioInputFormatValidator {
    public static func validate(sampleRate: Double, channels: UInt32) throws {
        guard sampleRate.isFinite, sampleRate > 0, channels > 0 else {
            throw AudioCaptureError.invalidSourceFormat(sampleRate: sampleRate, channels: channels)
        }
    }
}

public final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var capturing = false
    private var tapInstalled = false

    public init() {}

    var isHoldingAudioEngine: Bool { engine != nil }

    public func start() throws {
        try start(onAudioLevel: nil)
    }

    public func start(onAudioLevel: (@Sendable (Float) -> Void)?) throws {
        guard !capturing else { return }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw AudioCaptureError.inputDeviceUnavailable
        }

        releaseAudioEngine()
        let engine = AVAudioEngine()
        self.engine = engine
        do {
            let input = engine.inputNode
            let sourceFormat = input.inputFormat(forBus: 0)
            try AudioInputFormatValidator.validate(
                sampleRate: sourceFormat.sampleRate,
                channels: UInt32(sourceFormat.channelCount)
            )
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else {
                throw AudioCaptureError.invalidTargetFormat
            }
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw AudioCaptureError.converterCreationFailed
            }

            lock.withLock { samples.removeAll(keepingCapacity: true) }
            self.converter = converter
            self.targetFormat = targetFormat
            input.installTap(onBus: 0, bufferSize: 1_024, format: sourceFormat) { [weak self] buffer, _ in
                self?.appendConverted(buffer, onAudioLevel: onAudioLevel)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            capturing = true
        } catch {
            releaseAudioEngine()
            throw error
        }
    }

    public func stop() -> [Float] {
        let wasCapturing = capturing
        releaseAudioEngine()
        return lock.withLock {
            defer { samples.removeAll(keepingCapacity: true) }
            return wasCapturing ? samples : []
        }
    }

    public func cancel() {
        _ = stop()
    }

    private func releaseAudioEngine() {
        guard let engine else {
            capturing = false
            tapInstalled = false
            converter = nil
            targetFormat = nil
            return
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        engine.reset()
        self.engine = nil
        capturing = false
        tapInstalled = false
        converter = nil
        targetFormat = nil
    }

    private func appendConverted(
        _ input: AVAudioPCMBuffer,
        onAudioLevel: (@Sendable (Float) -> Void)?
    ) {
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outputStatus in
            guard !supplied else {
                outputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?.pointee else { return }
        let converted = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        lock.withLock { samples.append(contentsOf: converted) }
        guard !converted.isEmpty else { return }
        let meanSquare = converted.reduce(Float.zero) { partial, sample in
            partial + sample * sample
        } / Float(converted.count)
        onAudioLevel?(sqrt(meanSquare))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
