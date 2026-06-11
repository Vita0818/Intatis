#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisProviders
#if canImport(Security)
import Security
#endif

/// Thin wrapper over the macOS keychain (generic password items).
public struct KeychainStore {
    public let service: String
    public init(service: String) { self.service = service }

    public func set(_ value: String, account: String) throws {
        #if canImport(Security)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IntatisError.io("keychain write failed (OSStatus \(status))")
        }
        #else
        throw IntatisError.io("keychain unavailable on this platform")
        #endif
    }

    public func get(account: String) throws -> String {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw IntatisError.notFound("keychain item '\(account)'")
        }
        return string
        #else
        throw IntatisError.notFound("keychain unavailable on this platform")
        #endif
    }
}

/// Resolves provider secrets from the keychain using the ref's own service/account.
public struct KeychainSecretResolver: SecretResolver {
    public init() {}
    public func secret(for ref: KeychainRef) async throws -> String {
        try KeychainStore(service: ref.service).get(account: ref.account)
    }
}
#endif
