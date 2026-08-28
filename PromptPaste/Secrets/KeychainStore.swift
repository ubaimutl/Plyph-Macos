import Foundation
import Security

/// Keychain-backed storage for provider API keys/tokens.
///
/// GitHub CI artifacts are ad-hoc signed, so macOS can ask for keychain access
/// again when a new build has a different code hash. Cache successful reads in
/// memory for the lifetime of the process so one request does not prompt again
/// on every AI action. Properly signed release builds still use Keychain as the
/// persistent source of truth.
enum KeychainStore {
    static let service = "dev.ubai.PromptPaste"
    private static let credentialCache = NSCache<NSString, NSString>()

    enum KeychainError: LocalizedError {
        case unavailable(OSStatus)

        var status: OSStatus {
            switch self {
            case .unavailable(let status): return status
            }
        }

        var errorDescription: String? {
            switch self {
            case .unavailable(let status):
                return "Keychain is unavailable (error \(status)). Check your login keychain and try again."
            }
        }
    }

    static func read(provider: String) throws -> String {
        let cacheKey = provider as NSString
        if let cached = credentialCache.object(forKey: cacheKey) {
            return cached as String
        }

        var query = baseQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data else { return "" }
            let value = String(data: data, encoding: .utf8) ?? ""
            credentialCache.setObject(value as NSString, forKey: cacheKey)
            return value
        }
        if status == errSecItemNotFound {
            return ""
        }
        throw KeychainError.unavailable(status)
    }

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
            credentialCache.setObject(trimmed as NSString, forKey: provider as NSString)
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

        credentialCache.setObject(trimmed as NSString, forKey: provider as NSString)
    }

    static func delete(provider: String) throws {
        let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unavailable(status)
        }
        credentialCache.removeObject(forKey: provider as NSString)
    }

    private static func baseQuery(provider: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
    }
}
