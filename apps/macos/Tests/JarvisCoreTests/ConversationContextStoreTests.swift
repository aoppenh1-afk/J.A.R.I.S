import Foundation
import XCTest
@testable import JarvisCore

final class ConversationContextStoreTests: XCTestCase {
    func testSavesConversationAcrossStoreInstances() throws {
        let suiteName = "ConversationContextStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let turns = [
            ConversationTurn(userText: "What is 5 + 5?", assistantText: "10", provider: nil),
            ConversationTurn(userText: "Now add 2.", assistantText: "12", provider: nil)
        ]

        XCTAssertTrue(ConversationContextStore.save(turns, defaults: defaults))
        XCTAssertEqual(ConversationContextStore.load(defaults: defaults), turns)
    }

    func testRetainsEveryTurnWithinTheFiveMinuteWindow() throws {
        let suiteName = "ConversationContextStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let savedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let turns = (0..<75).map { index in
            ConversationTurn(userText: "user-\(index)", assistantText: "assistant-\(index)", provider: nil)
        }

        XCTAssertTrue(ConversationContextStore.save(turns, defaults: defaults, updatedAt: savedAt))
        XCTAssertEqual(ConversationContextStore.load(defaults: defaults, now: savedAt.addingTimeInterval(299)), turns)
    }

    func testExpiresConversationAfterFiveMinutesWithoutAnExchange() throws {
        let suiteName = "ConversationContextStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let savedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        _ = ConversationContextStore.save([
            ConversationTurn(userText: "hello", assistantText: "hi", provider: nil)
        ], defaults: defaults, updatedAt: savedAt)

        XCTAssertFalse(ConversationContextStore.load(defaults: defaults, now: savedAt.addingTimeInterval(300)).isEmpty)
        XCTAssertTrue(ConversationContextStore.load(defaults: defaults, now: savedAt.addingTimeInterval(301)).isEmpty)
        XCTAssertNil(ConversationContextStore.lastUpdatedAt(defaults: defaults))
    }

    func testClearRemovesSavedConversation() throws {
        let suiteName = "ConversationContextStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        _ = ConversationContextStore.save([
            ConversationTurn(userText: "hello", assistantText: "hi", provider: nil)
        ], defaults: defaults)

        ConversationContextStore.clear(defaults: defaults)

        XCTAssertTrue(ConversationContextStore.load(defaults: defaults).isEmpty)
    }
}
