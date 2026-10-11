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

    func testRetainsNewestTurnsWithinTheFiveMinuteWindow() throws {
        let suiteName = "ConversationContextStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let savedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let turns = (0..<75).map { index in
            ConversationTurn(userText: "user-\(index)", assistantText: "assistant-\(index)", provider: nil)
        }

        XCTAssertTrue(ConversationContextStore.save(turns, defaults: defaults, updatedAt: savedAt))
        XCTAssertEqual(ConversationContextStore.load(defaults: defaults, now: savedAt.addingTimeInterval(299)), Array(turns.suffix(ConversationContextStore.retentionLimit)))
    }

    func testBoundsLargeContextAndKeepsNewestExchange() {
        let turns = (0..<10).map { index in
            ConversationTurn(userText: "request-\(index)", assistantText: String(repeating: "a", count: 8_000), provider: nil)
        }
        let bounded = ConversationContextStore.bounded(turns)
        XCTAssertEqual(bounded.last?.userText, "request-9")
        XCTAssertLessThanOrEqual(bounded.reduce(0) { $0 + $1.userText.count + $1.assistantText.count },
                                 ConversationContextStore.characterLimit)
        XCTAssertEqual(bounded.map(\.id), Array(turns.suffix(bounded.count)).map(\.id))
    }

    func testTrimsOversizedLatestExchangeWithoutLosingItsIdentity() {
        let turn = ConversationTurn(userText: String(repeating: "u", count: 40_000),
                                    assistantText: String(repeating: "🙂", count: 40_000), provider: nil)
        let bounded = ConversationContextStore.bounded([turn])
        XCTAssertEqual(bounded.count, 1)
        XCTAssertEqual(bounded.first?.id, turn.id)
        XCTAssertEqual(bounded.first!.userText.count + bounded.first!.assistantText.count,
                       ConversationContextStore.characterLimit)
        XCTAssertFalse(bounded.first!.assistantText.isEmpty)
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
