import Combine
import Foundation

/// Central, persisted application settings. Mirrors the GNOME extension's
/// GSettings schema (same key names and defaults) on top of UserDefaults.
/// API credentials are intentionally absent — they live in the Keychain.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.registerDefaults(in: defaults)
        provider = defaults.string(forKey: "provider") ?? "groq"
        ollamaURL = defaults.string(forKey: "ollama-url") ?? ""
        ollamaModel = defaults.string(forKey: "ollama-model") ?? ""
        cloudflareAccountID = defaults.string(forKey: "cloudflare-account-id") ?? ""
        cloudflareModel = defaults.string(forKey: "cloudflare-model") ?? ""
        groqModel = defaults.string(forKey: "groq-model") ?? ""
        geminiModel = defaults.string(forKey: "gemini-model") ?? ""
        openRouterModel = defaults.string(forKey: "openrouter-model") ?? ""
        cerebrasModel = defaults.string(forKey: "cerebras-model") ?? ""
        openAIModel = defaults.string(forKey: "openai-model") ?? ""
        vercelModel = defaults.string(forKey: "vercel-model") ?? ""
        promptCorrect = defaults.string(forKey: "prompt-correct") ?? ""
        promptRewrite = defaults.string(forKey: "prompt-rewrite") ?? ""
        promptRun = defaults.string(forKey: "prompt-run") ?? ""
        promptRunProvider = defaults.string(forKey: "prompt-run-provider") ?? ""
        promptRunModel = defaults.string(forKey: "prompt-run-model") ?? ""
        promptRunInputLimit = defaults.integer(forKey: "prompt-run-input-limit")
        promptRunOutputLimit = defaults.integer(forKey: "prompt-run-output-limit")
        customActions = CustomActionStore.decode(
            defaults.string(forKey: "custom-actions") ?? "[]")
        previewResults = defaults.bool(forKey: "preview-results")
        clipboardFallback = defaults.bool(forKey: "clipboard-fallback")
        explicitCopyApps = defaults.string(forKey: "explicit-copy-apps") ?? ""
        excludedApps = defaults.string(forKey: "excluded-apps") ?? ""
        pointerFeedback = defaults.bool(forKey: "pointer-feedback")
        selectionDotEnabled = defaults.bool(forKey: "selection-dot-enabled")
        actionPalettePosition = defaults.string(forKey: "action-palette-position") ?? "disabled"
        variableLanguage = defaults.string(forKey: "variable-language") ?? ""
        variableTone = defaults.string(forKey: "variable-tone") ?? ""
        variableStyle = defaults.string(forKey: "variable-style") ?? ""
        correctShortcutJSON = defaults.string(forKey: "correct-shortcut") ?? ""
        rewriteShortcutJSON = defaults.string(forKey: "rewrite-shortcut") ?? ""
        actionsShortcutJSON = defaults.string(forKey: "actions-shortcut") ?? ""
        enableDebugLogging = defaults.bool(forKey: "enable-debug-logging")
    }

    // MARK: Defaults (GSettings schema parity)

    static let defaultPromptCorrect = """
        Correct grammar, spelling, punctuation, clarity, and style. Preserve the language, \
        meaning, and tone. Return only the corrected text, unchanged if already correct.
        """
    static let defaultPromptRewrite = """
        Rewrite for clarity and natural flow. Preserve the language, meaning, and tone. \
        Add no ideas or commentary. Return only the improved text.
        """
    static let defaultPromptRun = """
        Follow the provided instruction precisely. Produce the requested result directly. \
        Do not add introductory commentary unless requested.
        """

    static func registerDefaults(in defaults: UserDefaults) {
        defaults.register(defaults: [
            "provider": "groq",
            "ollama-url": "http://127.0.0.1:11434",
            "ollama-model": "qwen3:4b",
            "cloudflare-account-id": "",
            "cloudflare-model": "@cf/qwen/qwen3-30b-a3b-fp8",
            "groq-model": "openai/gpt-oss-20b",
            "openai-model": "gpt-4.1-mini",
            "gemini-model": "gemini-3.5-flash-lite",
            "openrouter-model": "openrouter/free",
            "vercel-model": "openai/gpt-5.4-mini",
            "cerebras-model": "gpt-oss-120b",
            "prompt-correct": defaultPromptCorrect,
            "prompt-rewrite": defaultPromptRewrite,
            "prompt-run": defaultPromptRun,
            "prompt-run-provider": "",
            "prompt-run-model": "",
            "prompt-run-input-limit": 0,
            "prompt-run-output-limit": 0,
            "custom-actions": CustomActionStore.encode(CustomAction.starterActions),
            "model-cache": "{}",
            "preview-results": true,
            "clipboard-fallback": false,
            "explicit-copy-apps": "firefox",
            "excluded-apps": "",
            "pointer-feedback": true,
            "selection-dot-enabled": false,
            "enable-debug-logging": false,
            "action-palette-position": "disabled",
            "variable-language": "English",
            "variable-tone": "professional",
            "variable-style": "clear and concise",
            "correct-shortcut": "",
            "rewrite-shortcut": "",
            "actions-shortcut": "",
        ])
    }

    // MARK: Provider

    @Published var provider: String {
        didSet { defaults.set(provider, forKey: "provider") }
    }

    @Published var ollamaURL: String {
        didSet { defaults.set(ollamaURL, forKey: "ollama-url") }
    }

    @Published var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: "ollama-model") }
    }

    @Published var cloudflareAccountID: String {
        didSet { defaults.set(cloudflareAccountID, forKey: "cloudflare-account-id") }
    }

    @Published var cloudflareModel: String {
        didSet { defaults.set(cloudflareModel, forKey: "cloudflare-model") }
    }

    @Published var groqModel: String {
        didSet { defaults.set(groqModel, forKey: "groq-model") }
    }

    @Published var geminiModel: String {
        didSet { defaults.set(geminiModel, forKey: "gemini-model") }
    }

    @Published var openRouterModel: String {
        didSet { defaults.set(openRouterModel, forKey: "openrouter-model") }
    }

    @Published var cerebrasModel: String {
        didSet { defaults.set(cerebrasModel, forKey: "cerebras-model") }
    }

    @Published var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: "openai-model") }
    }

    @Published var vercelModel: String {
        didSet { defaults.set(vercelModel, forKey: "vercel-model") }
    }

    func model(for providerID: String) -> String {
        switch providerID {
        case ProviderID.ollama.rawValue: return ollamaModel
        case ProviderID.cloudflare.rawValue: return cloudflareModel
        case ProviderID.groq.rawValue: return groqModel
        case ProviderID.gemini.rawValue: return geminiModel
        case ProviderID.openrouter.rawValue: return openRouterModel
        case ProviderID.cerebras.rawValue: return cerebrasModel
        case ProviderID.openai.rawValue: return openAIModel
        case ProviderID.vercel.rawValue: return vercelModel
        default: return ""
        }
    }

    func setModel(_ model: String, for providerID: String) {
        switch providerID {
        case ProviderID.ollama.rawValue: ollamaModel = model
        case ProviderID.cloudflare.rawValue: cloudflareModel = model
        case ProviderID.groq.rawValue: groqModel = model
        case ProviderID.gemini.rawValue: geminiModel = model
        case ProviderID.openrouter.rawValue: openRouterModel = model
        case ProviderID.cerebras.rawValue: cerebrasModel = model
        case ProviderID.openai.rawValue: openAIModel = model
        case ProviderID.vercel.rawValue: vercelModel = model
        default: break
        }
    }

    // MARK: Prompts and variables

    @Published var promptCorrect: String {
        didSet { defaults.set(promptCorrect, forKey: "prompt-correct") }
    }

    @Published var promptRewrite: String {
        didSet { defaults.set(promptRewrite, forKey: "prompt-rewrite") }
    }

    @Published var promptRun: String {
        didSet { defaults.set(promptRun, forKey: "prompt-run") }
    }

    @Published var promptRunProvider: String {
        didSet { defaults.set(promptRunProvider, forKey: "prompt-run-provider") }
    }

    @Published var promptRunModel: String {
        didSet { defaults.set(promptRunModel, forKey: "prompt-run-model") }
    }

    @Published var promptRunInputLimit: Int {
        didSet { defaults.set(promptRunInputLimit, forKey: "prompt-run-input-limit") }
    }

    @Published var promptRunOutputLimit: Int {
        didSet { defaults.set(promptRunOutputLimit, forKey: "prompt-run-output-limit") }
    }

    @Published var variableLanguage: String {
        didSet { defaults.set(variableLanguage, forKey: "variable-language") }
    }

    @Published var variableTone: String {
        didSet { defaults.set(variableTone, forKey: "variable-tone") }
    }

    @Published var variableStyle: String {
        didSet { defaults.set(variableStyle, forKey: "variable-style") }
    }

    // MARK: Behavior

    @Published var previewResults: Bool {
        didSet { defaults.set(previewResults, forKey: "preview-results") }
    }

    @Published var clipboardFallback: Bool {
        didSet { defaults.set(clipboardFallback, forKey: "clipboard-fallback") }
    }

    @Published var explicitCopyApps: String {
        didSet { defaults.set(explicitCopyApps, forKey: "explicit-copy-apps") }
    }

    /// Bundle identifiers where automatic selection UI must never appear.
    /// Stored as a newline-delimited string so the preference remains easy to
    /// inspect and migrate without coupling it to a Codable representation.
    @Published var excludedApps: String {
        didSet { defaults.set(excludedApps, forKey: "excluded-apps") }
    }

    @Published var pointerFeedback: Bool {
        didSet { defaults.set(pointerFeedback, forKey: "pointer-feedback") }
    }

    @Published var selectionDotEnabled: Bool {
        didSet { defaults.set(selectionDotEnabled, forKey: "selection-dot-enabled") }
    }

    @Published var enableDebugLogging: Bool {
        didSet { defaults.set(enableDebugLogging, forKey: "enable-debug-logging") }
    }

    /// "disabled" | "monitor-center" | "near-pointer"
    @Published var actionPalettePosition: String {
        didSet { defaults.set(actionPalettePosition, forKey: "action-palette-position") }
    }

    // MARK: Custom actions

    @Published var customActions: [CustomAction] {
        didSet { defaults.set(CustomActionStore.encode(customActions), forKey: "custom-actions") }
    }

    var enabledCustomActions: [CustomAction] {
        customActions.filter { $0.enabled }
    }

    // MARK: Shortcuts (JSON strings; empty means unset)

    @Published var correctShortcutJSON: String {
        didSet { defaults.set(correctShortcutJSON, forKey: "correct-shortcut") }
    }

    @Published var rewriteShortcutJSON: String {
        didSet { defaults.set(rewriteShortcutJSON, forKey: "rewrite-shortcut") }
    }

    @Published var actionsShortcutJSON: String {
        didSet { defaults.set(actionsShortcutJSON, forKey: "actions-shortcut") }
    }

    var correctShortcut: HotKeyCombo {
        get { HotKeyCombo.from(jsonString: correctShortcutJSON) }
        set { correctShortcutJSON = newValue.jsonString }
    }

    var rewriteShortcut: HotKeyCombo {
        get { HotKeyCombo.from(jsonString: rewriteShortcutJSON) }
        set { rewriteShortcutJSON = newValue.jsonString }
    }

    var actionsShortcut: HotKeyCombo {
        get { HotKeyCombo.from(jsonString: actionsShortcutJSON) }
        set { actionsShortcutJSON = newValue.jsonString }
    }

    // MARK: Compatibility apps

    /// Splits the explicit-copy app list the same way the GNOME extension does
    /// (comma or newline separated, trimmed, lowercased, empty entries removed).
    var explicitCopyAppList: [String] {
        explicitCopyApps
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    var excludedAppIdentifierList: [String] {
        Self.parseAppIdentifiers(excludedApps)
    }

    func isAppExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return Set(excludedAppIdentifierList).contains(bundleIdentifier.lowercased())
    }

    func excludeApp(bundleIdentifier: String) {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !identifier.isEmpty else { return }
        var identifiers = excludedAppIdentifierList
        guard !identifiers.contains(identifier) else { return }
        identifiers.append(identifier)
        excludedApps = identifiers.joined(separator: "\n")
    }

    func includeApp(bundleIdentifier: String) {
        let identifier = bundleIdentifier.lowercased()
        excludedApps = excludedAppIdentifierList
            .filter { $0 != identifier }
            .joined(separator: "\n")
    }

    private static func parseAppIdentifiers(_ value: String) -> [String] {
        var seen = Set<String>()
        return value
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
