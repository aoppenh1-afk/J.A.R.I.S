import Foundation
import Security

public enum InstallationIdentity {
    private static let service = "ai.jarvis.voice-assistant"
    private static let sessionAccount = "hermes-session-key"
    private static let apiKeyAccount = "hermes-api-key"
    private static let deepgramAccount = "deepgram-api-key"

    public static func hermesSessionKey() -> String {
        if let existing = readKeychainString(account: sessionAccount), !existing.isEmpty {
            return existing
        }

        let generated = "jarvis:desktop:\(UUID().uuidString)"
        if storeKeychainString(generated, account: sessionAccount) {
            return generated
        }

        let defaultsKey = "jarvis.hermesSessionKey"
        if let fallback = UserDefaults.standard.string(forKey: defaultsKey) {
            return fallback
        }
        UserDefaults.standard.set(generated, forKey: defaultsKey)
        return generated
    }

    public static func hermesAPIKey() -> String {
        if let existing = readKeychainString(account: apiKeyAccount), !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        _ = storeKeychainString(generated, account: apiKeyAccount)
        return generated
    }

    public static func deepgramAPIKey() -> String? {
        ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"]
            ?? readKeychainString(account: deepgramAccount)
    }

    @discardableResult
    public static func setDeepgramAPIKey(_ value: String?) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: deepgramAccount,
            ]
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        return storeKeychainString(value, account: deepgramAccount)
    }

    private static func readKeychainString(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func storeKeychainString(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let key: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insertion = key
        insertion[kSecValueData] = data
        return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
    }
}
