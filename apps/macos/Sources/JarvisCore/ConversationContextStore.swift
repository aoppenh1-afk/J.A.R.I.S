import Foundation

public enum ConversationContextStore {
    public static let expiration: TimeInterval = 300
    public static let retentionLimit = 12
    public static let characterLimit = 24_000
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
        return bounded(context.turns)
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
        guard let data = try? JSONEncoder().encode(StoredContext(updatedAt: updatedAt, turns: bounded(turns))) else {
            return false
        }
        defaults.set(data, forKey: key)
        return true
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// Keep the newest exchanges under a fixed prompt budget. An oversized latest
    /// exchange keeps its request and the beginning of the answer.
    public static func bounded(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        var retained: [ConversationTurn] = []
        var remaining = characterLimit
        for turn in turns.suffix(retentionLimit).reversed() {
            let size = turn.userText.count + turn.assistantText.count
            if size > remaining {
                if retained.isEmpty {
                    let user = String(turn.userText.prefix(characterLimit / 2))
                    let assistant = String(turn.assistantText.prefix(characterLimit - user.count))
                    retained.append(ConversationTurn(
                        id: turn.id, userText: user, assistantText: assistant,
                        provider: turn.provider, sources: turn.sources
                    ))
                }
                break
            }
            retained.append(turn)
            remaining -= size
        }
        return retained.reversed()
    }

    private static func storedContext(defaults: UserDefaults) -> StoredContext? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredContext.self, from: data)
    }
}
