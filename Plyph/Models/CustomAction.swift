import Foundation

/// How the selected text is fed to the model.
enum InputMode: String, Codable, CaseIterable {
    /// The selection is content to be transformed; the action prompt is the instruction.
    case transform
    /// The selection is used directly as the user prompt; the action prompt is optional
    /// system guidance.
    case prompt
}

/// A user-defined action, stored as JSON in `custom-actions`, mirroring the GNOME
/// `actions.js` shape: id, name, prompt, enabled, provider/model overrides,
/// input mode and token limits.
struct CustomAction: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String
    var enabled: Bool
    /// Empty string means "use the active provider".
    var provider: String
    /// Empty string means "use the provider's configured model".
    var model: String
    var inputMode: InputMode
    /// 0 means automatic (no limit).
    var inputLimit: Int
    /// 0 means automatic (no explicit limit).
    var outputLimit: Int

    init(
        id: String = UUID().uuidString,
        name: String,
        prompt: String,
        enabled: Bool = true,
        provider: String = "",
        model: String = "",
        inputMode: InputMode = .transform,
        inputLimit: Int = 0,
        outputLimit: Int = 0
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.enabled = enabled
        self.provider = provider
        self.model = model
        self.inputMode = inputMode
        self.inputLimit = max(0, inputLimit)
        self.outputLimit = max(0, outputLimit)
    }

    /// Useful, editable examples shown on a fresh installation. Stable IDs
    /// keep these distinguishable from actions users create themselves.
    static let starterActions: [CustomAction] = [
        CustomAction(
            id: "starter-summarize-v1",
            name: "Summarize",
            prompt: """
                Summarize the selected text as a concise paragraph or short bullet list, \
                whichever is clearer. Preserve key facts, names, numbers, and conclusions. \
                Add no commentary. Return only the summary.
                """),
        CustomAction(
            id: "starter-translate-v1",
            name: "Translate",
            prompt: """
                Translate the selected text into ${language}. Preserve its meaning, tone, \
                formatting, names, and technical terms. Return only the translation.
                """),
        CustomAction(
            id: "starter-tone-v1",
            name: "Adjust tone",
            prompt: """
                Rewrite the selected text in a ${tone} tone. Preserve its language, meaning, \
                facts, and essential formatting. Return only the revised text.
                """),
    ]

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, enabled, provider, model
        case inputMode
        case inputLimit
        case outputLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        inputMode = try container.decodeIfPresent(InputMode.self, forKey: .inputMode) ?? .transform
        inputLimit = Self.sanitizeLimit(try container.decodeIfPresent(Int.self, forKey: .inputLimit))
        outputLimit = Self.sanitizeLimit(try container.decodeIfPresent(Int.self, forKey: .outputLimit))
    }

    /// GNOME treats invalid limits as "no limit".
    static func sanitizeLimit(_ value: Int?) -> Int {
        guard let value, value > 0 else { return 0 }
        return value
    }

    /// Whether the action is valid the same way `actions.js` filters rows:
    /// it needs a name and, in transform mode, a prompt.
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (inputMode == .prompt
                || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Single-line summary used in the actions list, mirroring the GNOME row subtitle.
    var summarySubtitle: String {
        var parts: [String] = []
        if let provider = Providers.info(for: self.provider) {
            parts.append(
                provider.name + (model.isEmpty ? "" : " — \(model)"))
        } else {
            parts.append("Uses active provider and model")
        }
        if inputMode == .prompt {
            parts.append("Uses selected text as the prompt")
        }
        if inputLimit > 0 || outputLimit > 0 {
            parts.append(
                "Limits: input \(Self.formatTokenLimit(inputLimit)), "
                    + "output \(Self.formatTokenLimit(outputLimit))")
        }
        let preview = Self.promptPreview(prompt)
        if !preview.isEmpty {
            parts.append(preview)
        }
        return parts.joined(separator: "\n")
    }

    static func formatTokenLimit(_ value: Int) -> String {
        guard value > 0 else { return "Auto" }
        return value % 1000 == 0 ? "\(value / 1000)K" : String(value)
    }

    /// Compact single-line prompt preview (at most 140 characters).
    static func promptPreview(_ prompt: String, maximum: Int = 140) -> String {
        let compact = prompt
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard compact.count > maximum else { return compact }
        return String(compact.prefix(maximum)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// JSON (de)serialization for the `custom-actions` setting, including the same
/// normalization `actions.js` performs when reading.
enum CustomActionStore {
    static func decode(_ json: String) -> [CustomAction] {
        guard let data = json.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([CustomAction].self, from: data)
        else { return [] }
        return decoded.filter { $0.isValid }
    }

    static func encode(_ actions: [CustomAction]) -> String {
        guard let data = try? JSONEncoder().encode(actions) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
