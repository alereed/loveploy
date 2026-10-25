import Foundation
import LoveployCore
import Security

/// Stores secrets in the login Keychain: the Lovable session and the optional GitHub token.
enum Keychain {
    private static let service = "mx.blender.loveploy"

    static func loadCredentials() -> LovableCredentials? {
        guard let data = load(account: "lovable-session") else { return nil }
        return try? JSONDecoder().decode(LovableCredentials.self, from: data)
    }

    static func saveCredentials(_ credentials: LovableCredentials?) {
        guard let credentials, let data = try? JSONEncoder().encode(credentials) else {
            delete(account: "lovable-session")
            return
        }
        save(data, account: "lovable-session")
    }

    static func loadGitHubToken() -> String? {
        load(account: "github-token").map { String(decoding: $0, as: UTF8.self) }
    }

    static func saveGitHubToken(_ token: String?) {
        if let token {
            save(Data(token.utf8), account: "github-token")
        } else {
            delete(account: "github-token")
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

    private static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
