import Foundation
import XCTest
@testable import JarvisCore

final class ConversationHistoryStoreTests: XCTestCase {
    func testRetainsOnlyNewestFiftyTurns() throws {
        let suiteName = "ConversationHistoryStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let turns = (0..<75).map { index in
            ConversationTurn(
                userText: "user-\(index)",
                assistantText: "assistant-\(index)",
                provider: .local
            )
        }

        XCTAssertTrue(ConversationHistoryStore.save(turns, defaults: defaults))
        let loaded = ConversationHistoryStore.load(defaults: defaults)

        XCTAssertEqual(loaded.count, 50)
        XCTAssertEqual(loaded.first?.userText, "user-25")
        XCTAssertEqual(loaded.last?.userText, "user-74")
    }

    func testClearRemovesPersistedHistory() throws {
        let suiteName = "ConversationHistoryStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        _ = ConversationHistoryStore.save([
            ConversationTurn(userText: "hello", assistantText: "hi", provider: .deepgram)
        ], defaults: defaults)

        ConversationHistoryStore.clear(defaults: defaults)

        XCTAssertTrue(ConversationHistoryStore.load(defaults: defaults).isEmpty)
    }
}
