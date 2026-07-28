import Foundation

public enum ConversationContextStore {
    public static let expiration: TimeInterval = 300
    private static let key = "jarvis.conversationContext.v1"

    private struct StoredContext: Codable {
        let updatedAt: Date
        let turns: [ConversationTurn]
    }

    public static func load(
        defaults: UserDefaults = .standard,
        now: Date = .now
    ) -> [ConversationTurn] {
        guard let context = storedContext(defaults: defaults) else { return [] }
        guard now.timeIntervalSince(context.updatedAt) <= expiration else {
            clear(defaults: defaults)
            return []
        }
        return context.turns
    }

    public static func lastUpdatedAt(defaults: UserDefaults = .standard) -> Date? {
        storedContext(defaults: defaults)?.updatedAt
    }

    @discardableResult
    public static func save(
        _ turns: [ConversationTurn],
        defaults: UserDefaults = .standard,
        updatedAt: Date = .now
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(StoredContext(updatedAt: updatedAt, turns: turns)) else {
            return false
        }
        defaults.set(data, forKey: key)
        return true
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    private static func storedContext(defaults: UserDefaults) -> StoredContext? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredContext.self, from: data)
    }
}
