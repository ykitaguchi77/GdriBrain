import Foundation
import Security

/// Keychain wrapper.
///
/// Security choices (see README → セキュリティ):
/// - All items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The device
///   must be unlocked to read; items are not included in encrypted iCloud
///   backups and don't restore to a different device.
/// - We do NOT set `kSecAttrAccessGroup`. The Anthropic API key in particular
///   stays in the main-app Keychain; the Share Extension never reads it. The
///   Share Extension only enqueues drafts to the App Group container; the
///   main app drains the queue with the API key.
struct KeychainStore {
    enum Key: String {
        case anthropicAPIKey = "anthropic_api_key"
        case googleRefreshToken = "google_refresh_token"
        case googleAccessTokenCache = "google_access_token_cache"
    }

    static let service = "com.ykitaguchi.gdribrain"

    @discardableResult
    static func save(_ key: Key, value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func load(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static func mask(_ value: String?, leading: Int = 7, trailing: Int = 4) -> String {
        guard let v = value, v.count > leading + trailing + 3 else {
            return value?.isEmpty == false ? "••••" : ""
        }
        let head = v.prefix(leading)
        let tail = v.suffix(trailing)
        return "\(head)••••\(tail)"
    }
}
