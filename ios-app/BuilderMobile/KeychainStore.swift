import Foundation
import Security

enum KeychainStore {
    private static let service = "com.xte1.BuilderMobile"
    private static let tokenAccount = "github-token"
    static let anthropicAccount = "anthropic-api-key"

    // MARK: Generic storage

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    static func save(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func loadString(account: String) -> String? {
        load(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func saveString(_ value: String, account: String) throws {
        try save(Data(value.utf8), account: account)
    }

    // MARK: GitHub token (unchanged API)

    static func loadToken() -> String? { loadString(account: tokenAccount) }
    static func saveToken(_ token: String) throws { try saveString(token, account: tokenAccount) }
    static func deleteToken() { delete(account: tokenAccount) }
}
