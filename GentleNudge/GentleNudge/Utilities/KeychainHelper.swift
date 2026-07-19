import Foundation
import Security

/// Minimal wrapper around the iOS/macOS Keychain for storing small secrets
/// (like the Claude API key) securely instead of in UserDefaults.
enum KeychainHelper {
    /// Stores a string value for the given account key. Passing nil deletes the item.
    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        // Always remove any existing item first so we don't get duplicate errors.
        delete(account)

        guard let value, let data = value.data(using: .utf8) else {
            return true // nil/empty means "deleted", which we've already done
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Available after first unlock; survives backups but not transferable to other devices.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Reads the string value for the given account key, or nil if absent.
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
