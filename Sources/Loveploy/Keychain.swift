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

/// Stores secrets in the login Keychain: the Lovable API keys (as one JSON item) and the GitHub token.
enum Keychain {
    private static let service = "mx.blender.loveploy"

    static func loadKeys() -> [APIKeyEntry] {
        guard let data = load(account: "api-keys") else { return [] }
        return (try? JSONDecoder().decode([APIKeyEntry].self, from: data)) ?? []
    }

    static func saveKeys(_ keys: [APIKeyEntry]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        save(data, account: "api-keys")
    }

    static func loadGitHubToken() -> String? {
        load(account: "github-token").map { String(decoding: $0, as: UTF8.self) }
    }

    static func saveGitHubToken(_ token: String?) {
        if let token {
            save(Data(token.utf8), account: "github-token")
        } else {
            SecItemDelete(query(account: "github-token") as CFDictionary)
        }
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load(account: String) -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func save(_ data: Data, account: String) {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(account: account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account: account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
