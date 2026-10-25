import Foundation
import Security

/// Secrets (server token, Anthropic API key) live only in the Keychain (spec §12, §13).
protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String?)
}

struct KeychainStore: SecretStore {
    static let service = "com.chevin.fengshui"

    func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func set(_ key: String, _ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        // Available after first unlock, so background syncs can read it; never synced to iCloud.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var d: [String: String] = [:]
    init(_ initial: [String: String] = [:]) { d = initial }
    func get(_ key: String) -> String? { lock.withLock { d[key] } }
    func set(_ key: String, _ value: String?) { lock.withLock { d[key] = value } }
}

enum SecretKey {
    static let serverToken = "server_token"
    static let anthropicKey = "anthropic_api_key"
}
