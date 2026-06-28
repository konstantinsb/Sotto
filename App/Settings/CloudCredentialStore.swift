import Foundation
import Security

/// API-ключи облачных LLM в Keychain. Секрет НЕ хранится в UserDefaults — только в
/// Keychain (`...WhenUnlockedThisDeviceOnly`), по образцу `KeychainKey` из ядра.
/// Ключ адресуется по `account` провайдера (Anthropic/OpenAI хранятся раздельно и
/// не затирают друг друга — у пользователя могут быть оба).
enum CloudCredentialStore {
    private static let service = "com.konstantin.sotto"

    static func loadAPIKey(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    static func saveAPIKey(_ key: String, account: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        // Пустой ключ — просто удаляем запись (выключение облака не оставляет секрет).
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var add = base
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
