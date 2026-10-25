import Foundation
import Security

/// One Lovable API key. Keys are workspace-scoped, so one per workspace.
struct APIKeyEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var key: String

    var masked: String {
        guard key.count > 10 else { return "••••" }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }
}

/// Stores the API keys as a single JSON item in the login Keychain.
enum Keychain {
    private static let service = "mx.blender.loveploy"
    private static let account = "api-keys"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func loadKeys() -> [APIKeyEntry] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return []
        }
        return (try? JSONDecoder().decode([APIKeyEntry].self, from: data)) ?? []
    }

    static func saveKeys(_ keys: [APIKeyEntry]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }
}
