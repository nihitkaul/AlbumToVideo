import Foundation
import Security

enum KeychainTokenStore {
    private static let service = "com.albumtovideo.google.oauth"
    private static let account = "default"

    struct StoredTokens: Sendable {
        var accessToken: String
        var refreshToken: String?
        var accessExpiry: Date?
    }

    static func save(_ tokens: StoredTokens) throws {
        var payload: [String: Any] = ["access": tokens.accessToken]
        if let r = tokens.refreshToken { payload["refresh"] = r }
        if let e = tokens.accessExpiry { payload["exp"] = e.timeIntervalSince1970 }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load() throws -> StoredTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let dict = json, let access = dict["access"] as? String else { return nil }
        let refresh = dict["refresh"] as? String
        let exp: Date? = (dict["exp"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
        return StoredTokens(accessToken: access, refreshToken: refresh, accessExpiry: exp)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
