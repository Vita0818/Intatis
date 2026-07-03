#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisProviders
#if canImport(Security)
import Security
#endif

/// iOS keychain glue (per-app platform code — §4.4). Same generic-password API as
/// macOS; kept local to the iOS target to avoid touching the macOS app.
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
        guard status == errSecSuccess else { throw IntatisError.io("keychain write failed (OSStatus \(status))") }
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
        guard status == errSecSuccess, let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw IntatisError.notFound("keychain item '\(account)'")
        }
        return string
        #else
        throw IntatisError.notFound("keychain unavailable on this platform")
        #endif
    }

    public func exists(account: String) -> Bool {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
        #else
        return false
        #endif
    }
}

public final class KeychainSecretResolver: SecretResolver, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    public init() {}

    public func secret(for ref: KeychainRef) async throws -> String {
        let cacheKey = Self.cacheKey(for: ref)
        if let cached = cachedSecret(for: cacheKey) { return cached }

        let secret: String
        switch ref.source {
        case .keychain:
            secret = try KeychainStore(service: ref.service).get(account: ref.account)
        case .environment:
            guard let value = ProcessInfo.processInfo.environment[ref.account],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IntatisError.notFound("environment secret '\(ref.account)'")
            }
            secret = value
        case .file:
            secret = try Self.readSecretFile(path: ref.account)
        case .authFile:
            secret = try Self.readAuthFileSecret(providerID: ref.account)
        }
        cache(secret, for: ref)
        return secret
    }

    public func cache(_ secret: String, for ref: KeychainRef) {
        store(secret, for: Self.cacheKey(for: ref))
    }

    private func cachedSecret(for cacheKey: String) -> String? {
        lock.lock()
        let cached = cache[cacheKey]
        lock.unlock()
        return cached
    }

    private func store(_ secret: String, for cacheKey: String) {
        lock.lock()
        cache[cacheKey] = secret
        lock.unlock()
    }

    public static func exists(_ ref: KeychainRef, keychain: KeychainStore) -> Bool {
        switch ref.source {
        case .keychain:
            return keychain.exists(account: ref.account)
        case .environment:
            return !(ProcessInfo.processInfo.environment[ref.account] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .file:
            return FileManager.default.fileExists(atPath: expandedPath(ref.account))
        case .authFile:
            return FileManager.default.fileExists(atPath: authFileURL().path)
        }
    }

    private static func cacheKey(for ref: KeychainRef) -> String {
        "\(ref.source.rawValue)\u{1F}\(ref.service)\u{1F}\(ref.account)"
    }

    private static func readSecretFile(path: String) throws -> String {
        let url = URL(fileURLWithPath: expandedPath(path))
        let data = try Data(contentsOf: url)
        guard let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            throw IntatisError.notFound("empty secret file '\(path)'")
        }
        return value
    }

    private static func readAuthFileSecret(providerID: String) throws -> String {
        let data = try Data(contentsOf: authFileURL())
        let object = try JSONSerialization.jsonObject(with: data)
        if let flat = object as? [String: String],
           let value = flat[providerID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let root = object as? [String: Any],
           let providers = root["providers"] as? [String: String],
           let value = providers[providerID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        throw IntatisError.notFound("auth file secret for provider '\(providerID)'")
    }

    private static func authFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["INTATIS_AUTH_FILE"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: expandedPath(override))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Intatis/auth.json")
    }

    private static func expandedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "~" || trimmed.hasPrefix("~/") else { return trimmed }
        let home = NSHomeDirectory()
        if trimmed == "~" { return home }
        return home + String(trimmed.dropFirst())
    }
}
#endif
