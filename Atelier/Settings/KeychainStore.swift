// SPDX-License-Identifier: MIT
import Foundation
import Security
import os

/// Minimal wrapper around `Security.framework` for storing a single
/// `ANTHROPIC_API_KEY` value in the macOS user keychain.
///
/// Service: `app.atelier` (matches the bundle id).
/// Account: `ANTHROPIC_API_KEY`.
///
/// Reads return `nil` when nothing is stored or the keychain is locked (we
/// don't prompt — caller falls back to env var or subscription mode).
enum KeychainStore {
    private static let logger = Logger(subsystem: "app.atelier", category: "keychain")
    private static let service = "app.atelier"
    private static let account = "ANTHROPIC_API_KEY"

    /// Reads the stored key, or nil if not set.
    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                logger.warning("keychain read status=\(status)")
            }
            return nil
        }
        return str
    }

    /// Writes (or overwrites) the API key. Empty string deletes the entry.
    static func saveAPIKey(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try deleteAPIKey()
            return
        }
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        // Try update first.
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.osStatus(updateStatus)
        }
        // Not found → insert.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.osStatus(addStatus)
        }
    }

    /// Removes the stored key, if any. Idempotent.
    static func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.osStatus(status)
        }
    }

    enum KeychainError: Swift.Error, LocalizedError {
        case osStatus(OSStatus)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .osStatus(let s):
                if let msg = SecCopyErrorMessageString(s, nil) as String? {
                    return "Keychain error: \(msg) (\(s))"
                }
                return "Keychain error: \(s)"
            case .encodingFailed:
                return "Could not encode key as UTF-8."
            }
        }
    }
}

/// Resolves which API key to actually use at spawn time, in priority order:
///   1. macOS Keychain (`KeychainStore.loadAPIKey()`)
///   2. `ANTHROPIC_API_KEY` env var inherited from the launching shell
///   3. nil → defer to claude CLI's stored OAuth creds (Pro/Max subscription)
enum APIKeyResolver {
    static func resolve() -> String {
        if let stored = KeychainStore.loadAPIKey(), !stored.isEmpty {
            return stored
        }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        return ""
    }

    enum Source {
        case keychain
        case environment
        case subscription
    }

    static func describeSource() -> Source {
        if let s = KeychainStore.loadAPIKey(), !s.isEmpty { return .keychain }
        if let e = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !e.isEmpty { return .environment }
        return .subscription
    }
}
