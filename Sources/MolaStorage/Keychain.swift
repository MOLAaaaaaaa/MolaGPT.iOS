import Foundation
import Security

/// 密钥存储（对应安卓 CredentialStore：EncryptedSharedPreferences → iOS Keychain）。
/// key 命名与安卓一致：`byok.provider.api_key:<id>`、`byok.mcp_server.token:<id>`、`byok.web_search.api_key:<provider>`。
public enum Keychain {
    static let service = "com.molagpt.app.credentials"

    public enum Key {
        public static func providerApiKey(_ id: String) -> String { "byok.provider.api_key:\(id)" }
        public static func mcpToken(_ id: String) -> String { "byok.mcp_server.token:\(id)" }
        public static func webSearchKey(_ provider: String) -> String { "byok.web_search.api_key:\(provider)" }
    }

    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public static func get(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func set(_ key: String, _ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return delete(key) }
        let data = Data(value.utf8)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(base(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var q = base(key)
            q.merge(attrs) { _, b in b }
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    public static func delete(_ key: String) -> Bool {
        let s = SecItemDelete(base(key) as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}
