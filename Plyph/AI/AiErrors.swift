import Foundation

/// Domain errors surfaced to the user, with the same wording philosophy as the
/// GNOME version (specific, actionable messages instead of generic failures).
enum PromptError: LocalizedError {
    case noSelection
    case selectionCaptureFailed
    case releaseShortcutKeys
    case returnToOriginalApp
    case inputLimitExceeded(estimated: Int, limit: Int)
    case outputLimitReached
    case invalidResponse(status: Int)
    case providerRejectedKey(String)
    case providerModelNotFound(String, String)
    case providerTimeout(String)
    case providerRateLimit(String)
    case providerUnavailable(String, Int)
    case providerRejected(String, Int, String?)
    case providerUnexpectedResponse(String, String?)
    case missingCredential(String)
    case missingCloudflareAccount
    case keychainUnavailable(OSStatus)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return "Select text first."
        case .selectionCaptureFailed:
            return "Could not capture selected text. Select it and try again."
        case .releaseShortcutKeys:
            return "Release the shortcut keys and try again."
        case .returnToOriginalApp:
            return "Return to the original app before undoing."
        case .inputLimitExceeded(let estimated, let limit):
            return "Selected text is about \(estimated) tokens, above this action's "
                + "\(limit)-token input limit. Select less text or raise the limit."
        case .outputLimitReached:
            return "Response reached the output limit. Try a custom action with a higher "
                + "output limit, or select less text."
        case .invalidResponse(let status):
            return "Invalid response (\(status))"
        case .providerRejectedKey(let name):
            return "\(name) rejected the API key. Check it in Settings."
        case .providerModelNotFound(let name, let model):
            return "\(name) could not find model “\(model)”."
        case .providerTimeout(let name):
            return "\(name) timed out. Try again."
        case .providerRateLimit(let name):
            return "\(name) rate limit reached. Wait and try again."
        case .providerUnavailable(let name, let status):
            return "\(name) is temporarily unavailable (\(status))."
        case .providerRejected(let name, let status, let detail):
            return detail ?? "\(name) rejected the request (\(status))."
        case .providerUnexpectedResponse(let name, let detail):
            return detail ?? "\(name) returned an unexpected response."
        case .missingCredential(let name):
            return "Add a \(name) API key in Settings."
        case .missingCloudflareAccount:
            return "Add your Cloudflare Account ID in Settings."
        case .keychainUnavailable(let status):
            return "Keychain is unavailable (error \(status)). Check your login keychain and try again."
        case .network(let message):
            return message
        }
    }
}

/// Mapping of HTTP status codes and provider payloads to user-facing errors,
/// ported from the GNOME `ai.js` `providerError()`.
enum ProviderErrorMapper {
    /// Extracts `error.message` (or a plain string `error`) from a provider payload.
    static func detail(from data: [String: Any]) -> String? {
        if let error = data["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.isEmpty
        {
            return message
        }
        if let message = data["error"] as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    static func error(
        status: Int, data: [String: Any], providerName: String, model: String
    ) -> Error {
        let detail = Self.detail(from: data)
        switch status {
        case 401, 403:
            if providerName == Providers.info(for: .cloudflare).name {
                return PromptError.providerRejectedKey(
                    "Cloudflare rejected the API token or Account ID. Check them in Settings.")
                    as Error
            }
            return PromptError.providerRejectedKey(providerName)
        case 404:
            if providerName == Providers.info(for: .cloudflare).name {
                return PromptError.providerRejectedKey(
                    "Cloudflare could not find the account or model “\(model)”.")
            }
            return PromptError.providerModelNotFound(providerName, model)
        case 408:
            return PromptError.providerTimeout(providerName)
        case 429:
            return PromptError.providerRateLimit(providerName)
        case 500...599:
            return PromptError.providerUnavailable(providerName, status)
        case 400...499:
            return PromptError.providerRejected(providerName, status, detail)
        default:
            return PromptError.providerUnexpectedResponse(providerName, detail)
        }
    }

    /// Maps network-layer failures to friendly messages (port of `networkError()`).
    static func networkError(_ error: Error) -> Error {
        let urlError = error as? URLError
        switch urlError?.code {
        case .timedOut:
            return PromptError.network("The request timed out. Try again.")
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed:
            return PromptError.network(
                "Could not connect. Check your internet connection or local server.")
        default:
            return error
        }
    }
}
