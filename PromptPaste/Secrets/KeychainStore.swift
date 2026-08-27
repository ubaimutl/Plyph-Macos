import Foundation
import Security

/// Keychain-backed storage for provider API keys/tokens, mirroring the GNOME
/// version's Secret Service storage (one secret per provider). Keys are never
/// written to UserDefaults or plain files.
enum KeychainStore {
    static let service = "dev.ubai.PromptPaste"

    enum KeychainError: LocalizedError {
        case unavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unavailable(let status):
                return "Keychain is unavailable (error \(status)). Check your login keychain and try again."
            }
        }
    }

    /// Reads the stored credential for a provider, or "" when none is stored.
    static func read(provider: String) throws -> String {
        var query = baseQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        if status == errSecItemNotFound {
            return ""
        }
        throw KeychainError.unavailable(status)
    }

    /// Stores a credential; an empty value removes it (like the GNOME version).
    static func write(_ value: String, provider: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(provider: provider)
            return
        }

        let query = baseQuery(provider: provider)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unavailable(updateStatus)
        }

        var addQuery = query
        for (key, value) in attributes {
            addQuery[key] = value
        }
        addQuery[kSecAttrLabel as String] = "PromptPaste \(provider) credential"
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.unavailable(addStatus)
        }
    }

    static func delete(provider: String) throws {
        let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unavailable(status)
        }
    }

    private static func baseQuery(provider: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
    }
}
