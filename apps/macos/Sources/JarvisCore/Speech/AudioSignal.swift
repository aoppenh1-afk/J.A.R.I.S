import Foundation

public enum AudioSignal {
    public static func isLikelySilent(
        _ samples: [Float],
        threshold: Double = AppConfig.CaptureProfile.normal.silenceRMSThreshold
    ) -> Bool {
        guard !samples.isEmpty else { return true }
        let meanSquare = samples.reduce(into: 0.0) { sum, sample in
            let value = Double(sample)
            sum += value * value
        } / Double(samples.count)
        return sqrt(meanSquare) < threshold
    }
}
