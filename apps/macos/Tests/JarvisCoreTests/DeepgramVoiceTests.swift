import XCTest
@testable import JarvisCore

final class DeepgramVoiceTests: XCTestCase {
    func testCatalogContainsCurrentDefaultVoice() {
        let voice = DeepgramVoice.voice(for: "aura-2-thalia-en")

        XCTAssertEqual(voice?.name, "Thalia")
        XCTAssertEqual(voice?.detail, "English · Aura-2")
    }

    func testCatalogModelIdentifiersAreUnique() {
        let modelIDs = DeepgramVoice.englishAura2.map(\.modelID)

        XCTAssertEqual(modelIDs.count, 41)
        XCTAssertEqual(Set(modelIDs).count, modelIDs.count)
    }

    func testUnknownModelRemainsAvailableForCustomEntry() {
        XCTAssertNil(DeepgramVoice.voice(for: "aura-future-custom"))
    }
}
