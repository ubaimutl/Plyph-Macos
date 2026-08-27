import Foundation

/// Value snapshot of everything the AI client needs from settings. Built on the
/// main actor before a request so the client itself stays free of UI state.
struct AiConfig {
    var provider: String
    var ollamaURL: String
    var cloudflareAccountID: String
    var promptCorrect: String
    var promptRewrite: String
    var promptRun: String
    var variableLanguage: String
    var variableTone: String
    var variableStyle: String

    func model(for providerID: String) -> String {
        SettingsStore.shared.model(for: providerID)
    }

    static func from(_ settings: SettingsStore) -> AiConfig {
        AiConfig(
            provider: settings.provider,
            ollamaURL: settings.ollamaURL,
            cloudflareAccountID: settings.cloudflareAccountID,
            promptCorrect: settings.promptCorrect,
            promptRewrite: settings.promptRewrite,
            promptRun: settings.promptRun,
            variableLanguage: settings.variableLanguage,
            variableTone: settings.variableTone,
            variableStyle: settings.variableStyle)
    }
}

/// How the selected text is used in the request.
enum RequestInputMode {
    case transform
    case prompt
}

/// The action being run, mirroring the GNOME `transform()` modes.
enum RunMode: Equatable {
    case correct
    case rewrite
    case prompt
    case custom(CustomAction)

    static func == (lhs: RunMode, rhs: RunMode) -> Bool {
        switch (lhs, rhs) {
        case (.correct, .correct), (.rewrite, .rewrite), (.prompt, .prompt):
            return true
        case let (.custom(left), .custom(right)):
            return left == right
        default:
            return false
        }
    }
}

/// Per-run overrides (provider, model, limits, input mode), equivalent to the
/// options object the GNOME extension passes into `AiClient.transform()`.
struct RunOptions {
    var provider: String = ""
    var model: String = ""
    var inputMode: InputMode = .transform
    var inputLimit: Int = 0
    var outputLimit: Int = 0
}

/// AI client, an exact behavioral port of the GNOME `ai.js`: same prompt
/// envelope, token math, provider-specific request shapes, output cleaning,
/// truncation detection and error mapping.
struct AiClient {
    static let shared = AiClient()

    /// Session with the same 45-second timeout the GNOME version uses.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    // MARK: Prompt helpers (ported from ai.js)

    static func payload(_ text: String) -> String {
        "Transform only the text inside the tags.\n"
            + "Return only the transformed text.\n<text>\n\(text)\n</text>"
    }

    static func messages(_ prompt: String, _ text: String, _ inputMode: RequestInputMode)
        -> [[String: String]]
    {
        var items: [[String: String]] = []
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(["role": "system", "content": prompt])
        }
        items.append([
            "role": "user",
            "content": inputMode == .prompt ? text : payload(text),
        ])
        return items
    }

    static func tokenLimit(_ value: Int) -> Int {
        value > 0 ? value : 0
    }

    static func estimateTokens(_ text: String) -> Int {
        // GNOME uses the UTF-16 length of the string.
        Int(ceil(Double(text.utf16.count) / 4.0))
    }

    static func maxTokens(_ text: String, _ outputLimit: Int = 0) -> Int {
        let explicit = tokenLimit(outputLimit)
        if explicit > 0 { return explicit }
        return min(2000, max(220, estimateTokens(text) + 180))
    }

    /// Strips the `<text>` envelope and code fences the model may wrap around
    /// transformed output (transform mode only).
    static func cleanOutput(_ text: String, inputMode: RequestInputMode) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inputMode == .prompt {
            return output
        }
        let taggedPrefix = "<text>"
        let taggedSuffix = "</text>"
        if output.lowercased().hasPrefix(taggedPrefix),
            output.lowercased().hasSuffix(taggedSuffix),
            output.count >= taggedPrefix.count + taggedSuffix.count
        {
            let start = output.index(output.startIndex, offsetBy: taggedPrefix.count)
            let end = output.index(output.endIndex, offsetBy: -taggedSuffix.count)
            output = String(output[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if output.hasPrefix("```"), output.hasSuffix("```"), output.count >= 6 {
            var inner = String(output.dropFirst(3).dropLast(3))
            if inner.lowercased().hasPrefix("text") {
                inner = String(inner.dropFirst(4))
            }
            output = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return output
    }

    /// Single-pass `${selection}` / `${language}` / `${tone}` / `${style}`
    /// expansion (a selection containing `${tone}` is not re-expanded, matching
    /// the one-shot regex behavior of the GNOME version).
    static func expandPrompt(_ prompt: String, text: String, config: AiConfig) -> String {
        var result = ""
        var index = prompt.startIndex
        while index < prompt.endIndex {
            if prompt[index] == "$" {
                let next = prompt.index(after: index)
                if next < prompt.endIndex, prompt[next] == "{" {
                    if let close = prompt[next...].firstIndex(of: "}") {
                        let name = String(prompt[prompt.index(after: next)..<close])
                        switch name {
                        case "selection":
                            result += text
                            index = prompt.index(after: close)
                            continue
                        case "language":
                            result += config.variableLanguage
                            index = prompt.index(after: close)
                            continue
                        case "tone":
                            result += config.variableTone
                            index = prompt.index(after: close)
                            continue
                        case "style":
                            result += config.variableStyle
                            index = prompt.index(after: close)
                            continue
                        default:
                            break
                        }
                    }
                }
            }
            result.append(prompt[index])
            index = prompt.index(after: index)
        }
        return result
    }

    // MARK: Transform entry point

    /// Port of `AiClient.transform()`.
    func transform(
        text: String,
        mode: RunMode,
        customPrompt: String?,
        options: RunOptions,
        config: AiConfig,
        credentialProvider: (String) throws -> String = { try KeychainStore.read(provider: $0) }
    ) async throws -> String {
        let inputMode: RequestInputMode =
            (mode == RunMode.prompt || options.inputMode == .prompt) ? .prompt : .transform
        let hasActionLimits: Bool
        if case RunMode.custom = mode { hasActionLimits = true } else {
            hasActionLimits = mode == RunMode.prompt
        }
        let inputLimit = hasActionLimits ? Self.tokenLimit(options.inputLimit) : 0
        let estimatedTokens = Self.estimateTokens(text)
        if inputLimit > 0 && estimatedTokens > inputLimit {
            throw PromptError.inputLimitExceeded(estimated: estimatedTokens, limit: inputLimit)
        }
        var outputLimit = hasActionLimits ? Self.tokenLimit(options.outputLimit) : 0
        if inputMode == .prompt && outputLimit == 0 {
            outputLimit = 2000
        }

        let selectedProvider = options.provider.isEmpty ? config.provider : options.provider
        let provider = Providers.info(for: selectedProvider) != nil
            ? selectedProvider
            : ProviderID.groq.rawValue
        let model = options.model.isEmpty ? config.model(for: provider) : options.model

        let storedPrompt: String
        switch mode {
        case .rewrite:
            storedPrompt = config.promptRewrite
        case .prompt:
            storedPrompt = config.promptRun
        case .correct, .custom:
            storedPrompt = config.promptCorrect
        }
        let prompt = Self.expandPrompt(customPrompt ?? storedPrompt, text: text, config: config)

        do {
            switch provider {
            case ProviderID.ollama.rawValue:
                return try await ollama(
                    text, prompt, model, inputMode, outputLimit, config)
            case ProviderID.cloudflare.rawValue:
                return try await cloudflare(
                    text, prompt, model, inputMode, outputLimit, config, credentialProvider)
            case ProviderID.openai.rawValue:
                return try await openAI(
                    text, prompt, model, inputMode, outputLimit, credentialProvider)
            case ProviderID.gemini.rawValue:
                return try await gemini(
                    text, prompt, model, inputMode, outputLimit, credentialProvider)
            case ProviderID.openrouter.rawValue:
                return try await openRouter(
                    text, prompt, model, inputMode, outputLimit, credentialProvider)
            case ProviderID.vercel.rawValue:
                return try await vercel(
                    text, prompt, model, inputMode, outputLimit, credentialProvider)
            case ProviderID.cerebras.rawValue:
                return try await cerebras(
                    text, prompt, model, inputMode, outputLimit, credentialProvider)
            default:
                return try await groq(
                    text, prompt, model, inputMode, outputLimit, credentialProvider)
            }
        } catch {
            throw ProviderErrorMapper.networkError(error)
        }
    }

    // MARK: Shared request helpers

    struct RequestResult {
        let status: Int
        let data: [String: Any]
    }

    func requestJSON(
        url: URL, headers: [String: String], body: [String: Any]
    ) async throws -> RequestResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        var parsed: [String: Any] = [:]
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsed = object
        } else if status < 400 {
            // GNOME only treats unparseable bodies as an error for non-error statuses;
            // otherwise the providerError mapping runs against an empty payload.
            throw PromptError.invalidResponse(status: status)
        }
        return RequestResult(status: status, data: parsed)
    }

    /// Port of `outputOrError()` for OpenAI-compatible responses.
    func outputOrError(
        _ result: RequestResult, providerName: String, model: String,
        inputMode: RequestInputMode
    ) throws -> String {
        if let choices = result.data["choices"] as? [[String: Any]],
            let first = choices.first,
            let finishReason = first["finish_reason"] as? String,
            finishReason == "length"
        {
            throw PromptError.outputLimitReached
        }
        let content = ((result.data["choices"] as? [[String: Any]])?.first?["message"]
            as? [String: Any])?["content"] as? String
        let output = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty {
            return Self.cleanOutput(output, inputMode: inputMode)
        }
        throw ProviderErrorMapper.error(
            status: result.status, data: result.data, providerName: providerName, model: model)
    }

    static func openAIBody(
        _ model: String, _ prompt: String, _ text: String,
        _ inputMode: RequestInputMode, _ outputLimit: Int, cerebras: Bool = false
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": messages(prompt, text, inputMode),
        ]
        body[cerebras ? "max_completion_tokens" : "max_tokens"] = maxTokens(text, outputLimit)
        return body
    }

    // MARK: Providers

    func groq(
        _ text: String, _ prompt: String, _ model: String,
        _ inputMode: RequestInputMode, _ outputLimit: Int,
        _ credentialProvider: (String) throws -> String
    ) async throws -> String {
        let key = try await required(ProviderID.groq, credentialProvider)
        let body = Self.openAIBody(model, prompt, text, inputMode, outputLimit)
        var requestBody = body
        if model.hasPrefix("openai/gpt-oss-") {
            requestBody["reasoning_effort"] = "low"
            requestBody["include_reasoning"] = false
        }
        let result = try await requestJSON(
            url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(key)"],
            body: requestBody)
        return try outputOrError(result, providerName: "Groq", model: model, inputMode: inputMode)
    }

    func cloudflare(
        _ text: String, _ prompt: String, _ model: String,
        _ inputMode: RequestInputMode, _ outputLimit: Int,
        _ config: AiConfig,
        _ credentialProvider: (String) throws -> String
    ) async throws -> String {
        let key = try await required(ProviderID.cloudflare, credentialProvider)
        let accountID = config.cloudflareAccountID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if accountID.isEmpty {
            throw PromptError.missingCloudflareAccount
        }
        let encoded = accountID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? accountID
        let result = try await requestJSON(
            url: URL(
                string:
                    "https://api.cloudflare.com/client/v4/accounts/\(encoded)/ai/v1/chat/completions"
            )!,
            headers: ["Authorization": "Bearer \(key)"],
            body: Self.openAIBody(model, prompt, text, inputMode, outputLimit))
        return try outputOrError(
            result, providerName: Providers.info(for: .cloudflare).name, model: model,
            inputMode: inputMode)
    }

    func ollama(
        _ text: String, _ prompt: String, _ model: String,
        _ inputMode: RequestInputMode, _ outputLimit: Int,
        _ config: AiConfig
    ) async throws -> String {
        let base = config.ollamaURL
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        var body: [String: Any] = [
            "model": model,
            "messages": Self.messages(prompt, text, inputMode),
            "stream": false,
        ]
        if outputLimit > 0 {
            body["options"] = ["num_predict": outputLimit]
        }
        let result = try await requestJSON(
            url: URL(string: "\(trimmed)/api/chat")!, headers: [:], body: body)
        if let doneReason = result.data["done_reason"] as? String, doneReason == "length" {
            throw PromptError.outputLimitReached
        }
        let content = (result.data["message"] as? [String: Any])?["content"] as? String
        let output = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty {
            return Self.cleanOutput(output, inputMode: inputMode)
        }
        throw ProviderErrorMapper.error(
            status: result.status, data: result.data,
            providerName: Providers.info(for: .ollama).name, model: model)
    }

    func openAI(
        _ text: String, _ prompt: String, _ model: String,
        _ inputMode: RequestInputMode, _ outputLimit: Int,
        _ credentialProvider: (String) throws -> String
    ) async throws -> String {
        let key = try await required(ProviderID.openai, credentialProvider)
        let result = try await requestJSON(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(key)"],
            body: Self.openAIBody(model, prompt, text, inputMode, outputLimit))
        return try outputOrError(
            result, providerName: Providers.info(for: .openai).name, model: model,
            inputMode: inputMode)
    }

    func gemini(
        _ text: String, _ prompt: String, _ model: String,
        _ inputMode: RequestInputMode, _ outputLimit: Int,
        _ credentialProvider: (String) throws -> String
    ) async throws -> String {
        let key = try await required(ProviderID.gemini, credentialProvider)
        var body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [["text": inputMode == .prompt ? text : Self.payload(text)]],
                ]
            ],
            "generationConfig": ["maxOutputTokens": Self.maxTokens(text, outputLimit)],
        ]
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["systemInstruction"] = ["parts": [["text": prompt]]]
        }
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        let result = try await requestJSON(url: components.url!, headers: [:], body: body)
        if let candidates = result.data["candidates"] as? [[String: Any]],
            let first = candidates.first,
            let finishReason = first["finishReason"] as? String,
            finishReason == "MAX_TOKENS"
        {
            throw PromptError.outputLimitReached
        }
        let parts = ((result.data["candidates"] as? [[String: Any]])?.first?["content"]
            as? [String: Any])?["parts"] as? [[String: Any]]
        let joined = parts?.compactMap { $0["text"] as? String }.joined() ?? ""
        let output = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            return Self.cleanOutput(output, inputMode: inputMode)
        }
        throw ProviderErrorMapper.error(
            status: result.status, data: result.data,
            providerName: Providers.info(for: .gemini).name, model: model)
    }

    func openRouter(
        _ text: String, _ prompt: String, _ model: String,
        _ inputMode: RequestInputMode, _ outputLimit: Int,
        _ credentialProvider: (String) throws -> String
    ) async throws -> String {
        let key = try await required(ProviderID.openrouter, credentialProvider)
        let result = try await requestJSON(
            url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(key)", "X-Title": "PromptPaste"],
            body: Self.openAIBody(model, prompt, text, inputMode, outputLimit))
        return try outputOrError(
            result, providerName: Providers.info(for: .openrouter).name, model: model,
            inputMode: inputMode)
    }

    func vercel(
        _ text: String, _ prompt: String, _ model: String,
        _ inputMode: RequestInputMode, _ outputLimit: Int,
        _ credentialProvider: (String) throws -> String
    ) async throws -> String {
        let key = try await required(ProviderID.vercel, credentialProvider)
        let result = try await requestJSON(
            url: URL(string: "https://ai-gateway.vercel.sh/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(key)"],
            body: Self.openAIBody(model, prompt, text, inputMode, outputLimit))
        return try outputOrError(
            result, providerName: Providers.info(for: .vercel).name, model: model,
            inputMode: inputMode)
    }

    func cerebras(
        _ text: String, _ prompt: String, _ model: String,
        _ inputMode: RequestInputMode, _ outputLimit: Int,
        _ credentialProvider: (String) throws -> String
    ) async throws -> String {
        let key = try await required(ProviderID.cerebras, credentialProvider)
        let result = try await requestJSON(
            url: URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(key)"],
            body: Self.openAIBody(
                model, prompt, text, inputMode, outputLimit, cerebras: true))
        return try outputOrError(
            result, providerName: Providers.info(for: .cerebras).name, model: model,
            inputMode: inputMode)
    }

    func required(
        _ provider: ProviderID, _ credentialProvider: (String) throws -> String
    ) async throws -> String {
        let value: String
        do {
            value = try credentialProvider(provider.rawValue)
        } catch let error as KeychainStore.KeychainError {
            throw PromptError.keychainUnavailable(error.status)
        } catch {
            throw error
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if provider == .cloudflare {
                throw PromptError.network("Add a Cloudflare Workers AI API token in Settings.")
            }
            throw PromptError.missingCredential(Providers.info(for: provider).name)
        }
        return trimmed
    }
}
