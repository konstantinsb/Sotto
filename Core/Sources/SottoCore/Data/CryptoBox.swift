import Foundation
import CryptoKit
import Security

/// Симметричное шифрование чувствительных данных (транскрипты, summary, профиль).
/// AES-GCM (на Apple Silicon аппаратно — быстрее ChaCha). Ключ — в Keychain.
public struct CryptoBox: Sendable {
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Бокс с ключом приложения из Keychain (создаётся при первом обращении).
    public static func appBox() -> CryptoBox {
        CryptoBox(key: KeychainKey.loadOrCreate())
    }

    public func encrypt(_ plaintext: String) -> Data? {
        guard let data = plaintext.data(using: .utf8) else { return nil }
        return try? AES.GCM.seal(data, using: key).combined
    }

    public func encrypt(_ data: Data) -> Data? {
        try? AES.GCM.seal(data, using: key).combined
    }

    public func decryptString(_ ciphertext: Data) -> String? {
        guard let data = decryptData(ciphertext) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func decryptData(_ ciphertext: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

/// 256-битный ключ приложения в Keychain (`...WhenUnlockedThisDeviceOnly`).
public enum KeychainKey {
    private static let service = "com.konstantin.sotto"
    private static let account = "data-encryption-key"

    public static func loadOrCreate() -> SymmetricKey {
        if let existing = load() { return existing }
        let key = SymmetricKey(size: .bits256)
        store(key)
        return key
    }

    private static func load() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private static func store(_ key: SymmetricKey) {
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}
