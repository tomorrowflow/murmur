import Foundation
import Security

/// Storage for user secrets (gateway tokens, API keys), keyed by the same
/// keys the settings UI always used.
///
/// Bundled builds store secrets in the Keychain (encrypted at rest) and
/// transparently migrate any legacy plaintext UserDefaults value on first
/// read. Unbundled dev builds (`swift run Murmur`) keep using UserDefaults:
/// every rebuild produces a differently-signed binary, and the Keychain ACL
/// would throw an access prompt per secret per rebuild.
public enum SecretsStore {
    // Must detect a real .app bundle, not just a bundle identifier: the dev
    // binary embeds Info.plist via -sectcreate (for the system-audio
    // permission prompt), which makes bundleIdentifier non-nil under
    // `swift run` too — and routing dev builds to the Keychain reintroduces
    // the per-rebuild ACL prompt this split exists to avoid.
    private static let isBundled = Bundle.main.bundlePath.hasSuffix(".app")
    private static let service = "com.murmur.secrets"

    public static func get(_ key: String) -> String? {
        guard isBundled else {
            return UserDefaults.standard.string(forKey: key)
        }
        if let value = keychainGet(key) {
            return value
        }
        // Migrate a legacy plaintext value into the Keychain.
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            if keychainSet(legacy, forKey: key) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            return legacy
        }
        return nil
    }

    public static func set(_ value: String?, forKey key: String) {
        guard let value = value, !value.isEmpty else {
            if isBundled { keychainDelete(key) }
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        guard isBundled else {
            UserDefaults.standard.set(value, forKey: key)
            return
        }
        if keychainSet(value, forKey: key) {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            // Keychain unavailable for some reason — better a stored secret
            // than a silently lost one.
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    // MARK: - Keychain primitives

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private static func keychainGet(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func keychainSet(_ value: String, forKey key: String) -> Bool {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    private static func keychainDelete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}
