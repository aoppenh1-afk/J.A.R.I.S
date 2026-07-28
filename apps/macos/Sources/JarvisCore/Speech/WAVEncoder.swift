import Foundation

public enum WAVEncoder {
    public static func encodeMono16kPCM16(samples: [Float]) -> Data {
        let sampleRate: UInt32 = 16_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * bitsPerSample / 8
        let dataSize = UInt32(samples.count * MemoryLayout<Int16>.size)

        var data = Data()
        data.reserveCapacity(44 + Int(dataSize))
        data.append(contentsOf: "RIFF".utf8)
        append(36 + dataSize, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(channelCount, to: &data)
        append(sampleRate, to: &data)
        append(byteRate, to: &data)
        append(blockAlign, to: &data)
        append(bitsPerSample, to: &data)
        data.append(contentsOf: "data".utf8)
        append(dataSize, to: &data)

        for sample in samples {
            let normalized = min(1, max(-1, sample))
            append(Int16(normalized * Float(Int16.max)), to: &data)
        }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
