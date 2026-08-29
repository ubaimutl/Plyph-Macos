import Foundation

/// The AI providers supported by Plyph, mirroring the GNOME extension's
/// `models.js` registry (ids, display names, credential requirements,
/// default models and free-tier notes).
enum ProviderID: String, CaseIterable, Codable, Equatable {
    case ollama
    case groq
    case cloudflare
    case gemini
    case openrouter
    case cerebras
    case openai
    case vercel
}

struct ProviderInfo {
    let id: ProviderID
    let name: String
    /// Whether the provider needs a credential stored in the Keychain.
    let requiresKey: Bool
    /// The label used for the credential field ("API key" vs "API token").
    let credentialLabel: String
    let defaultModel: String
    /// Optional free-usage note shown in the provider settings, like the GNOME version.
    let freeUsageNote: String?

    /// Where the provider's configured model is persisted.
    var modelKey: String { "\(id.rawValue)-model" }
}

enum Providers {
    /// Display order matches the GNOME preferences window.
    static let all: [ProviderInfo] = [
        ProviderInfo(
            id: .ollama, name: "Ollama (local)", requiresKey: false,
            credentialLabel: "", defaultModel: "qwen3:4b", freeUsageNote: nil),
        ProviderInfo(
            id: .groq, name: "Groq", requiresKey: true,
            credentialLabel: "API key", defaultModel: "openai/gpt-oss-20b",
            freeUsageNote: "Free plan available. Limits vary by model and account."),
        ProviderInfo(
            id: .cloudflare, name: "Cloudflare Workers AI", requiresKey: true,
            credentialLabel: "API token", defaultModel: "@cf/qwen/qwen3-30b-a3b-fp8",
            freeUsageNote: "Free tier includes 10,000 Neurons per day."),
        ProviderInfo(
            id: .gemini, name: "Gemini", requiresKey: true,
            credentialLabel: "API key", defaultModel: "gemini-3.5-flash-lite", freeUsageNote: nil),
        ProviderInfo(
            id: .openrouter, name: "OpenRouter", requiresKey: true,
            credentialLabel: "API key", defaultModel: "openrouter/free", freeUsageNote: nil),
        ProviderInfo(
            id: .cerebras, name: "Cerebras", requiresKey: true,
            credentialLabel: "API key", defaultModel: "gpt-oss-120b",
            freeUsageNote: "Free plan available. Limits vary by model and account."),
        ProviderInfo(
            id: .openai, name: "OpenAI", requiresKey: true,
            credentialLabel: "API key", defaultModel: "gpt-4.1-mini", freeUsageNote: nil),
        ProviderInfo(
            id: .vercel, name: "Vercel AI Gateway", requiresKey: true,
            credentialLabel: "API key", defaultModel: "openai/gpt-5.4-mini",
            freeUsageNote: "Free accounts receive $5 of AI Gateway credit every 30 days after the first request."),
    ]

    static func info(for id: String) -> ProviderInfo? {
        all.first { $0.id.rawValue == id }
    }

    static func info(for id: ProviderID) -> ProviderInfo {
        // All ids come from `all`, so this cannot fail in practice.
        info(for: id.rawValue) ?? all[0]
    }

    static func displayName(for id: String) -> String {
        info(for: id)?.name ?? "Provider"
    }
}
