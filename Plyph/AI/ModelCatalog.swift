import Foundation

/// A model option offered by a provider.
struct ModelOption: Codable, Equatable, Identifiable {
    var id: String
    var name: String
}

/// Fetches and caches the model list for each provider — a port of the GNOME
/// `models.js`, including provider-specific endpoints, filters and error
/// messages. The cache is stored (non-secret) in the `model-cache` setting.
enum ModelCatalog {
    /// Session with the GNOME's 20-second model-fetch timeout.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    // MARK: Cache

    static func cachedModels(provider: String, defaults: UserDefaults = .standard)
        -> [ModelOption]
    {
        guard let json = defaults.string(forKey: "model-cache"),
            let data = json.data(using: .utf8),
            let cache = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = cache[provider] as? [[String: Any]]
        else { return [] }
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return ModelOption(id: id, name: (entry["name"] as? String) ?? id)
        }
    }

    static func cacheModels(_ models: [ModelOption], provider: String,
                            defaults: UserDefaults = .standard) {
        var cache: [String: Any] = [:]
        if let json = defaults.string(forKey: "model-cache"),
            let data = json.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            cache = parsed
        }
        cache[provider] = models.map { ["id": $0.id, "name": $0.name] }
        if let data = try? JSONSerialization.data(withJSONObject: cache) {
            defaults.set(String(data: data, encoding: .utf8) ?? "{}", forKey: "model-cache")
        }
    }

    // MARK: Fetching

    static func fetchModels(provider: String, config: AiConfig,
                            credentialProvider: (String) throws -> String = {
                                try KeychainStore.read(provider: $0)
                            }) async throws -> [ModelOption] {
        let models: [ModelOption]
        switch provider {
        case ProviderID.ollama.rawValue:
            models = try await fetchOllama(config: config)
        case ProviderID.cloudflare.rawValue:
            models = try await fetchCloudflare(config: config, credentialProvider)
        case ProviderID.gemini.rawValue:
            models = try await fetchGemini(credentialProvider)
        default:
            models = try await fetchOpenAICompatible(provider: provider, credentialProvider)
        }
        return uniqueSorted(models)
    }

    static func uniqueSorted(_ models: [ModelOption]) -> [ModelOption] {
        var seen = Set<String>()
        return models
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private static func getJSON(url: URL, headers: [String: String], providerName: String)
        async throws -> [String: Any]
    {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data
        let status: Int
        do {
            let (response, urlResponse) = try await session.data(for: request)
            data = response
            status = (urlResponse as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            let urlError = error as? URLError
            if urlError?.code == .timedOut {
                throw PromptError.network("\(providerName) timed out. Try again.")
            }
            switch urlError?.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed:
                throw PromptError.network("Could not connect to \(providerName).")
            default:
                throw error
            }
        }

        var parsed: [String: Any] = [:]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsed = object
        }
        guard status >= 200, status < 300 else {
            let detail = ProviderErrorMapper.detail(from: parsed)
            switch status {
            case 401, 403:
                throw PromptError.network(
                    "\(providerName) rejected the API key. Check it and try again.")
            case 404:
                throw PromptError.network("\(providerName) model list is unavailable.")
            case 408:
                throw PromptError.network("\(providerName) timed out. Try again.")
            case 429:
                throw PromptError.network("\(providerName) rate limit reached. Wait and try again.")
            case 500...599:
                throw PromptError.network(
                    "\(providerName) is temporarily unavailable (\(status)).")
            default:
                throw PromptError.network(
                    detail ?? "\(providerName) rejected the request (\(status)).")
            }
        }
        return parsed
    }

    private static func fetchOllama(config: AiConfig) async throws -> [ModelOption] {
        let base = config.ollamaURL
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        let data = try await getJSON(
            url: URL(string: "\(trimmed)/api/tags")!, headers: [:], providerName: "Ollama")
        let models = data["models"] as? [[String: Any]] ?? []
        return models.map { model in
            let id = (model["model"] as? String) ?? (model["name"] as? String) ?? ""
            return ModelOption(id: id, name: (model["name"] as? String) ?? id)
        }
    }

    private static func fetchCloudflare(
        config: AiConfig, _ credentialProvider: (String) throws -> String
    ) async throws -> [ModelOption] {
        let key: String
        do {
            key = try credentialProvider(ProviderID.cloudflare.rawValue)
        } catch let error as KeychainStore.KeychainError {
            throw PromptError.keychainUnavailable(error.status)
        }
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PromptError.network("Add a Cloudflare Workers AI API token first.")
        }
        let accountID = config.cloudflareAccountID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if accountID.isEmpty {
            throw PromptError.network("Add your Cloudflare Account ID first.")
        }
        let encoded = accountID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? accountID
        var components = URLComponents(
            string:
                "https://api.cloudflare.com/client/v4/accounts/\(encoded)/ai/models/search"
        )!
        components.queryItems = [
            URLQueryItem(name: "task", value: "Text Generation"),
            URLQueryItem(name: "hide_experimental", value: "true"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        let data = try await getJSON(
            url: components.url!, headers: ["Authorization": "Bearer \(key)"],
            providerName: Providers.info(for: .cloudflare).name)
        let results = data["result"] as? [[String: Any]] ?? []
        return results.map { model in
            let id = (model["name"] as? String) ?? (model["id"] as? String) ?? ""
            return ModelOption(id: id, name: (model["name"] as? String) ?? id)
        }
    }

    private static func fetchGemini(
        _ credentialProvider: (String) throws -> String
    ) async throws -> [ModelOption] {
        let key: String
        do {
            key = try credentialProvider(ProviderID.gemini.rawValue)
        } catch let error as KeychainStore.KeychainError {
            throw PromptError.keychainUnavailable(error.status)
        }
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PromptError.network(
                "Add a \(Providers.info(for: .gemini).name) API key first.")
        }
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [
            URLQueryItem(name: "pageSize", value: "1000"),
            URLQueryItem(name: "key", value: key),
        ]
        let data = try await getJSON(url: components.url!, headers: [:],
                                     providerName: Providers.info(for: .gemini).name)
        let models = data["models"] as? [[String: Any]] ?? []
        return models.compactMap { model in
            guard let methods = model["supportedGenerationMethods"] as? [String],
                methods.contains("generateContent")
            else { return nil }
            let rawName = model["name"] as? String ?? ""
            let id = rawName.hasPrefix("models/") ? String(rawName.dropFirst(7)) : rawName
            return ModelOption(
                id: id, name: (model["displayName"] as? String) ?? id)
        }
    }

    private static func fetchOpenAICompatible(
        provider: String, _ credentialProvider: (String) throws -> String
    ) async throws -> [ModelOption] {
        guard let info = Providers.info(for: provider) else {
            throw PromptError.network("Unknown provider.")
        }
        var key = ""
        if info.requiresKey {
            do {
                key = try credentialProvider(provider)
            } catch let error as KeychainStore.KeychainError {
                throw PromptError.keychainUnavailable(error.status)
            }
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PromptError.network("Add a \(info.name) API key first.")
            }
        }
        let endpoints: [String: String] = [
            ProviderID.groq.rawValue: "https://api.groq.com/openai/v1/models",
            ProviderID.openrouter.rawValue:
                "https://openrouter.ai/api/v1/models?output_modalities=text",
            ProviderID.cerebras.rawValue: "https://api.cerebras.ai/v1/models",
            ProviderID.openai.rawValue: "https://api.openai.com/v1/models",
            ProviderID.vercel.rawValue: "https://ai-gateway.vercel.sh/v1/models",
        ]
        guard let urlString = endpoints[provider],
            let url = URL(string: urlString)
        else { throw PromptError.network("Unknown provider.") }
        let data = try await getJSON(
            url: url, headers: key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"],
            providerName: info.name)
        let models = data["data"] as? [[String: Any]] ?? []
        var options: [ModelOption] = models.compactMap { model in
            if let type = model["type"] as? String, type != "language" {
                return nil
            }
            let id = model["id"] as? String ?? ""
            return ModelOption(id: id, name: (model["name"] as? String) ?? id)
        }
        if provider == ProviderID.openai.rawValue {
            options = options.filter { option in
                let id = option.id
                let matches = id.range(of: "^(gpt-|o\\d)", options: .regularExpression) != nil
                let excluded =
                    id.range(
                        of: "(audio|image|realtime|search|transcribe|tts)",
                        options: .regularExpression) != nil
                return matches && !excluded
            }
        } else if provider == ProviderID.groq.rawValue {
            options = options.filter { option in
                option.id.range(of: "(guard|whisper|tts)", options: [.regularExpression, .caseInsensitive]) == nil
            }
        }
        return options
    }

    /// Options for the picker: cached list plus the currently configured model
    /// when missing (port of `_setModelOptions`).
    static func pickerOptions(provider: String, current: String,
                              defaults: UserDefaults = .standard) -> [ModelOption] {
        var options = cachedModels(provider: provider, defaults: defaults)
        if !current.isEmpty && !options.contains(where: { $0.id == current }) {
            options.insert(ModelOption(id: current, name: current), at: 0)
        }
        return options
    }
}
