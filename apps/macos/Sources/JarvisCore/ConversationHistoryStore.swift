import Foundation

public enum ConversationHistoryStore {
    public static let retentionLimit = 50
    private static let key = "jarvis.conversationHistory.v1"

    public static func load(defaults: UserDefaults = .standard) -> [ConversationTurn] {
        guard let data = defaults.data(forKey: key),
              let turns = try? JSONDecoder().decode([ConversationTurn].self, from: data) else {
            return []
        }
        return Array(turns.suffix(retentionLimit))
    }

    @discardableResult
    public static func save(
        _ turns: [ConversationTurn],
        defaults: UserDefaults = .standard
    ) -> Bool {
        let retained = Array(turns.suffix(retentionLimit))
        guard let data = try? JSONEncoder().encode(retained) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
