import Foundation

enum BuiltInActionID: String, Codable, CaseIterable {
    case ask
    case correct
    case rewrite
    case prompt
}

/// Stable persisted reference to either a built-in action or one custom action.
struct ActionReference: Codable, Hashable, Identifiable {
    let rawValue: String
    var id: String { rawValue }

    static let ask = ActionReference(rawValue: "builtin:ask")
    static let correct = ActionReference(rawValue: "builtin:correct")
    static let rewrite = ActionReference(rawValue: "builtin:rewrite")
    static let prompt = ActionReference(rawValue: "builtin:prompt")

    static func custom(_ id: String) -> ActionReference {
        ActionReference(rawValue: "custom:\(id)")
    }

    var builtIn: BuiltInActionID? {
        guard rawValue.hasPrefix("builtin:") else { return nil }
        return BuiltInActionID(rawValue: String(rawValue.dropFirst("builtin:".count)))
    }

    var customID: String? {
        guard rawValue.hasPrefix("custom:") else { return nil }
        let value = String(rawValue.dropFirst("custom:".count))
        return value.isEmpty ? nil : value
    }
}

struct QuickActionConfiguration: Codable, Equatable {
    static let maximumCount = 4
    static let `default` = QuickActionConfiguration(
        actions: [.ask, .correct, .rewrite])

    var actions: [ActionReference]

    init(actions: [ActionReference]) {
        self.actions = Self.normalized(actions)
    }

    private enum CodingKeys: String, CodingKey { case actions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(actions: try container.decodeIfPresent(
            [ActionReference].self,
            forKey: .actions) ?? Self.default.actions)
    }

    static func normalized(_ actions: [ActionReference]) -> [ActionReference] {
        var seen = Set<ActionReference>()
        return actions
            .filter { seen.insert($0).inserted }
            .prefix(maximumCount)
            .map { $0 }
    }
}

struct AppActionProfile: Codable, Equatable, Identifiable {
    var bundleIdentifier: String
    var actions: [ActionReference]
    var id: String { bundleIdentifier.lowercased() }

    init(bundleIdentifier: String, actions: [ActionReference]) {
        self.bundleIdentifier = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.actions = QuickActionConfiguration.normalized(actions)
    }

    private enum CodingKeys: String, CodingKey { case bundleIdentifier, actions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bundleIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .bundleIdentifier) ?? "",
            actions: try container.decodeIfPresent(
                [ActionReference].self,
                forKey: .actions) ?? [])
    }
}

enum ActionOutputBehavior: String, Codable, CaseIterable, Hashable {
    case preview
    case replaceSelection
    case copyToClipboard
    case insertBeforeSelection
    case insertAfterSelection
    case openInAsk

    var title: String {
        switch self {
        case .preview: return "Preview"
        case .replaceSelection: return "Replace Selection"
        case .copyToClipboard: return "Copy to Clipboard"
        case .insertBeforeSelection: return "Insert Before Selection"
        case .insertAfterSelection: return "Insert After Selection"
        case .openInAsk: return "Open in Ask"
        }
    }
}

struct SelectionContext: Equatable {
    let text: String
    let bundleIdentifier: String?
    let isEditable: Bool

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSingleWord: Bool {
        let parts = trimmedText.split(whereSeparator: { $0.isWhitespace })
        return parts.count == 1 && !parts[0].isEmpty
    }

    var isURL: Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)^https?://[^\s]+$"#),
              !trimmedText.isEmpty else { return false }
        return expression.firstMatch(
            in: trimmedText,
            range: NSRange(trimmedText.startIndex..., in: trimmedText)) != nil
    }

    var isEmailAddress: Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#),
              !trimmedText.isEmpty else { return false }
        return expression.firstMatch(
            in: trimmedText,
            range: NSRange(trimmedText.startIndex..., in: trimmedText)) != nil
    }

    var looksLikeCode: Bool {
        let value = trimmedText
        guard !value.isEmpty else { return false }
        let codeTokens = [
            "func ", "class ", "struct ", "enum ", "import ", "return ",
            "const ", "let ", "var ", "def ", "=>", "</", "#include", "SELECT "
        ]
        if codeTokens.contains(where: { value.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        if value.contains("{") && value.contains("}") { return true }
        if value.contains("(") && value.contains(")") && value.contains(";") { return true }
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        let indented = lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count
        return lines.count >= 2 && indented >= max(1, lines.count / 3)
    }
}

enum ActionVisibilityCondition: Equatable, Codable, Identifiable {
    case always
    case editableTextOnly
    case singleWord
    case url
    case emailAddress
    case looksLikeCode
    case minimumLength(Int)
    case maximumLength(Int)
    case appBundleIdentifier(String)
    case excludedAppBundleIdentifier(String)

    var id: String {
        switch self {
        case .always: return "always"
        case .editableTextOnly: return "editable"
        case .singleWord: return "single-word"
        case .url: return "url"
        case .emailAddress: return "email"
        case .looksLikeCode: return "code"
        case .minimumLength(let value): return "min:\(value)"
        case .maximumLength(let value): return "max:\(value)"
        case .appBundleIdentifier(let value): return "app:\(value.lowercased())"
        case .excludedAppBundleIdentifier(let value): return "not-app:\(value.lowercased())"
        }
    }

    var title: String {
        switch self {
        case .always: return "Always"
        case .editableTextOnly: return "Editable text only"
        case .singleWord: return "Single word"
        case .url: return "URL"
        case .emailAddress: return "Email address"
        case .looksLikeCode: return "Looks like code"
        case .minimumLength(let value): return "At least \(value) characters"
        case .maximumLength(let value): return "At most \(value) characters"
        case .appBundleIdentifier(let value): return "Only in \(value)"
        case .excludedAppBundleIdentifier(let value): return "Not in \(value)"
        }
    }

    func matches(_ context: SelectionContext) -> Bool {
        switch self {
        case .always: return true
        case .editableTextOnly: return context.isEditable
        case .singleWord: return context.isSingleWord
        case .url: return context.isURL
        case .emailAddress: return context.isEmailAddress
        case .looksLikeCode: return context.looksLikeCode
        case .minimumLength(let value): return context.text.count >= max(0, value)
        case .maximumLength(let value): return context.text.count <= max(0, value)
        case .appBundleIdentifier(let value):
            return context.bundleIdentifier?.caseInsensitiveCompare(value) == .orderedSame
        case .excludedAppBundleIdentifier(let value):
            return context.bundleIdentifier?.caseInsensitiveCompare(value) != .orderedSame
        }
    }

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable {
        case always, editableTextOnly, singleWord, url, emailAddress, looksLikeCode
        case minimumLength, maximumLength, appBundleIdentifier
        case excludedAppBundleIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .always: self = .always
        case .editableTextOnly: self = .editableTextOnly
        case .singleWord: self = .singleWord
        case .url: self = .url
        case .emailAddress: self = .emailAddress
        case .looksLikeCode: self = .looksLikeCode
        case .minimumLength:
            self = .minimumLength(try container.decodeIfPresent(Int.self, forKey: .value) ?? 0)
        case .maximumLength:
            self = .maximumLength(try container.decodeIfPresent(Int.self, forKey: .value) ?? 0)
        case .appBundleIdentifier:
            self = .appBundleIdentifier(
                try container.decodeIfPresent(String.self, forKey: .value) ?? "")
        case .excludedAppBundleIdentifier:
            self = .excludedAppBundleIdentifier(
                try container.decodeIfPresent(String.self, forKey: .value) ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always: try container.encode(Kind.always, forKey: .type)
        case .editableTextOnly: try container.encode(Kind.editableTextOnly, forKey: .type)
        case .singleWord: try container.encode(Kind.singleWord, forKey: .type)
        case .url: try container.encode(Kind.url, forKey: .type)
        case .emailAddress: try container.encode(Kind.emailAddress, forKey: .type)
        case .looksLikeCode: try container.encode(Kind.looksLikeCode, forKey: .type)
        case .minimumLength(let value):
            try container.encode(Kind.minimumLength, forKey: .type)
            try container.encode(max(0, value), forKey: .value)
        case .maximumLength(let value):
            try container.encode(Kind.maximumLength, forKey: .type)
            try container.encode(max(0, value), forKey: .value)
        case .appBundleIdentifier(let value):
            try container.encode(Kind.appBundleIdentifier, forKey: .type)
            try container.encode(value.lowercased(), forKey: .value)
        case .excludedAppBundleIdentifier(let value):
            try container.encode(Kind.excludedAppBundleIdentifier, forKey: .type)
            try container.encode(value.lowercased(), forKey: .value)
        }
    }
}

enum ActionConfigurationStore {
    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum QuickActionResolver {
    static func references(
        global: QuickActionConfiguration,
        profiles: [AppActionProfile],
        bundleIdentifier: String?,
        excludedBundleIdentifiers: [String]
    ) -> [ActionReference] {
        let bundleID = bundleIdentifier?.lowercased()
        if let bundleID,
           excludedBundleIdentifiers.map({ $0.lowercased() }).contains(bundleID) {
            return []
        }
        if let bundleID,
           let profile = profiles.first(where: {
               $0.bundleIdentifier.caseInsensitiveCompare(bundleID) == .orderedSame
           }) {
            return QuickActionConfiguration.normalized(profile.actions)
        }
        return QuickActionConfiguration.normalized(global.actions)
    }
}
