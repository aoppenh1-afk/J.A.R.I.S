import XCTest
@testable import JarvisCore

final class WAVEncoderTests: XCTestCase {
    func testEncodesMono16kPCM16HeaderAndPayload() {
        let data = WAVEncoder.encodeMono16kPCM16(samples: [0, 1, -1])

        XCTAssertEqual(String(data: data[0..<4], encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .utf8), "data")
        XCTAssertEqual(data.count, 44 + 3 * MemoryLayout<Int16>.size)
        XCTAssertEqual(readUInt32(data, offset: 24), 16_000)
        XCTAssertEqual(readUInt16(data, offset: 22), 1)
        XCTAssertEqual(readUInt16(data, offset: 34), 16)
    }

    private func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}
