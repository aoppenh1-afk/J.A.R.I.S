import Accelerate
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
public struct AudioCaptureSignal: Sendable, Equatable {
    public let rms: Float
    public let bands: AudioFrequencyBands
    public var reachedRecordingLimit: Bool

    public init(rms: Float, bands: AudioFrequencyBands, reachedRecordingLimit: Bool = false) {
        self.rms = rms
        self.bands = bands
        self.reachedRecordingLimit = reachedRecordingLimit
    }

    static func analyze(samples: [Float], sampleRate: Double) -> AudioCaptureSignal {
        AudioSpectrumAnalyzer().analyze(samples: samples, sampleRate: sampleRate)
    }
}

struct AudioRecordingBuffer {
    static let maximumDuration: TimeInterval = 120
    private(set) var samples: [Float] = []
    let maximumSamples: Int

    init(maximumSamples: Int = Int(maximumDuration * 16_000)) {
        self.maximumSamples = max(0, maximumSamples)
    }

    mutating func append(_ incoming: UnsafeBufferPointer<Float>) -> Bool {
        let remaining = max(0, maximumSamples - samples.count)
        samples.append(contentsOf: incoming.prefix(remaining))
        return samples.count == maximumSamples
    }

    mutating func takeSamples() -> [Float] {
        let result = samples
        samples = []
        return result
    }
}

/// Mirrors the upstream Web Audio analyser: a 1024-sample Hann-windowed FFT,
/// per-bin decibel mapping, a 0.78 smoothing constant, and broad low/mid/high
/// frequency averages. Keeping the smoothing before band aggregation prevents
/// individual microphone buffers from making the listening wave visibly jump.
private final class AudioSpectrumAnalyzer {
    private static let fftSize = 1_024
    private static let binCount = fftSize / 2
    private static let spectrumSmoothing: Float = 0.78

    private let log2FFTSize = vDSP_Length(log2(Float(fftSize)))
    private let fftSetup: FFTSetup
    private var rollingSamples = [Float](repeating: 0, count: fftSize)
    private var window = [Float](repeating: 0, count: fftSize)
    private var windowedSamples = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: binCount)
    private var imaginary = [Float](repeating: 0, count: binCount)
    private var power = [Float](repeating: 0, count: binCount)
    private var smoothedSpectrum = [Float](repeating: 0, count: binCount)

    init() {
        guard let setup = vDSP_create_fftsetup(log2FFTSize, FFTRadix(kFFTRadix2)) else {
            fatalError("Unable to create the microphone spectrum FFT setup.")
        }
        fftSetup = setup
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func reset() {
        rollingSamples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
        smoothedSpectrum.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
    }

    func analyze(samples: [Float], sampleRate _: Double) -> AudioCaptureSignal {
        let meanSquare = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(samples.count, 1))
        let rms = sqrt(meanSquare)
        guard !samples.isEmpty else {
            return AudioCaptureSignal(rms: 0, bands: .zero)
        }

        appendToRollingWindow(samples)
        vDSP_vmul(
            rollingSamples, 1,
            window, 1,
            &windowedSamples, 1,
            vDSP_Length(Self.fftSize)
        )

        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imaginaryBuffer.baseAddress!
                )
                windowedSamples.withUnsafeBytes { rawBuffer in
                    let interleaved = rawBuffer.bindMemory(to: DSPComplex.self)
                    vDSP_ctoz(
                        interleaved.baseAddress!, 2,
                        &split, 1,
                        vDSP_Length(Self.binCount)
                    )
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2FFTSize, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.binCount))
            }
        }

        // Web Audio's default byte-frequency range maps roughly -100 dB to
        // -30 dB into [0, 1]. Apply the same mapping before its 0.78 smoothing.
        let amplitudeScale = 1 / Float(Self.fftSize)
        smoothedSpectrum[0] = 0 // Ignore DC, which otherwise dominates the low band.
        for index in 1..<Self.binCount {
            let amplitude = sqrt(max(power[index], 0)) * amplitudeScale
            let decibels = 20 * log10(max(amplitude, 0.000_000_1))
            let normalized = min(1, max(0, (decibels + 100) / 70))
            smoothedSpectrum[index] =
                smoothedSpectrum[index] * Self.spectrumSmoothing
                + normalized * (1 - Self.spectrumSmoothing)
        }

        let lowEnd = max(2, Int(Float(Self.binCount) * 0.08))
        let midEnd = max(lowEnd + 1, Int(Float(Self.binCount) * 0.40))
        let low = average(in: 1..<lowEnd)
        let mid = average(in: lowEnd..<midEnd)
        let high = average(in: midEnd..<Self.binCount)

        return AudioCaptureSignal(
            rms: rms,
            bands: AudioFrequencyBands(
                low: scaledBand(low, multiplier: 2.6),
                mid: scaledBand(mid, multiplier: 3.2),
                high: scaledBand(high, multiplier: 4.0)
            )
        )
    }

    private func appendToRollingWindow(_ samples: [Float]) {
        let appendedCount = min(samples.count, Self.fftSize)
        if appendedCount == Self.fftSize {
            rollingSamples.replaceSubrange(0..<Self.fftSize, with: samples.suffix(Self.fftSize))
            return
        }
        rollingSamples.removeFirst(appendedCount)
        rollingSamples.append(contentsOf: samples.suffix(appendedCount))
    }

    private func average(in range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        return smoothedSpectrum[range].reduce(0, +) / Float(range.count)
    }

    private func scaledBand(_ value: Float, multiplier: Float) -> Float {
        min(1, powf(max(0, value * multiplier), 0.8))
    }
}


public final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var recording = AudioRecordingBuffer()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var conversionBuffer: AVAudioPCMBuffer?
    private let spectrumAnalyzer = AudioSpectrumAnalyzer()
    private var capturing = false
    private var tapInstalled = false
    private var lastSignalUptime: TimeInterval = 0

    public init() {}

    var isHoldingAudioEngine: Bool { engine != nil }

    public func start() throws {
        try start(onAudioLevel: nil)
    }

    public func start(onAudioLevel: (@Sendable (Float) -> Void)?) throws {
        if let onAudioLevel {
            try start { signal in onAudioLevel(signal.rms) }
        } else {
            try start(onAudioSignal: nil)
        }
    }

    public func start(onAudioSignal: (@Sendable (AudioCaptureSignal) -> Void)?) throws {
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

            lock.withLock { recording = AudioRecordingBuffer() }
            spectrumAnalyzer.reset()
            lastSignalUptime = 0
            self.converter = converter
            self.targetFormat = targetFormat
            input.installTap(onBus: 0, bufferSize: 1_024, format: sourceFormat) { [weak self] buffer, _ in
                self?.appendConverted(buffer, onAudioSignal: onAudioSignal)
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
            let samples = recording.takeSamples()
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
            conversionBuffer = nil
            spectrumAnalyzer.reset()
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
        conversionBuffer = nil
        spectrumAnalyzer.reset()
    }

    private func appendConverted(
        _ input: AVAudioPCMBuffer,
        onAudioSignal: (@Sendable (AudioCaptureSignal) -> Void)?
    ) {
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        if (conversionBuffer?.frameCapacity ?? 0) < capacity {
            conversionBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        }
        guard let output = conversionBuffer else { return }
        output.frameLength = 0

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
        let converted = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        let reachedLimit = lock.withLock { recording.append(converted) }
        guard !converted.isEmpty, let onAudioSignal else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard reachedLimit || now - lastSignalUptime >= 1.0 / 30.0 else { return }
        lastSignalUptime = now
        var signal = spectrumAnalyzer.analyze(samples: Array(converted), sampleRate: targetFormat.sampleRate)
        signal.reachedRecordingLimit = reachedLimit
        onAudioSignal(signal)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
