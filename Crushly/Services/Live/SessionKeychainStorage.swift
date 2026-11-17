import Foundation
import Security
import Supabase

/// Stores the Supabase auth session in the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// (design §6.5). supabase-swift's default `KeychainLocalStorage` uses `AfterFirstUnlock`, which lets the session
/// travel to another device through encrypted backups and device-to-device transfer. `ThisDeviceOnly` keeps it on
/// this phone: a restored or migrated device has to sign in again.
///
/// Same service name as the library default, so sessions written by earlier builds are found and upgraded to the
/// stricter class the first time they're read (nobody gets signed out by the switch).
struct SessionKeychainStorage: AuthLocalStorage {
    static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let service: String

    init(service: String = "supabase.gotrue.swift") {
        self.service = service
    }

    func store(key: String, value: Data) throws {
        var add = baseQuery(key)
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = Self.accessibility
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [
                kSecValueData as String: value,
                kSecAttrAccessible as String: Self.accessibility,
            ]
            try check(SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary))
        } else {
            try check(status)
        }
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data else {
            return nil
        }
        // One-time upgrade of items written by the library default (AfterFirstUnlock).
        if let current = item[kSecAttrAccessible as String] as? String, current != (Self.accessibility as String) {
            let attributes: [String: Any] = [kSecAttrAccessible as String: Self.accessibility]
            _ = SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary)
        }
        return data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw CrushlyError.unknown("Keychain: \(message)")
        }
    }
}
