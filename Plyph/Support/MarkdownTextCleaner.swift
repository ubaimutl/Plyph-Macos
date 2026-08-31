import Foundation

/// Converts common Markdown output into readable plain text without changing
/// the model response until the user explicitly requests it in the preview.
enum MarkdownTextCleaner {
    static func plainText(from markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var insideFence = false
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> String? in
                var line = String(rawLine)

                if line.range(
                    of: #"^\s*(`{3,}|~{3,}).*$"#,
                    options: .regularExpression) != nil
                {
                    insideFence.toggle()
                    return nil
                }

                // Remove horizontal rules and table separator rows, which carry
                // formatting rather than useful content in plain text.
                if !insideFence
                    && (line.range(
                        of: #"^\s{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})\s*$"#,
                        options: .regularExpression) != nil
                        || line.range(
                            of: #"^\s*\|?\s*:?-{3,}:?(\s*\|\s*:?-{3,}:?)+\s*\|?\s*$"#,
                            options: .regularExpression) != nil)
                {
                    return nil
                }

                if !insideFence {
                    line = replacing(#"^\s{0,3}#{1,6}\s+"#, in: line, with: "")
                    line = replacing(#"^\s{0,3}>\s?"#, in: line, with: "")
                    line = replacing(#"^(\s*)[-+*]\s+\[x\]\s+"#, in: line, with: "$1☒ ", caseInsensitive: true)
                    line = replacing(#"^(\s*)[-+*]\s+\[\s\]\s+"#, in: line, with: "$1☐ ")
                    line = replacing(#"^(\s*)[-+*]\s+"#, in: line, with: "$1• ")
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                        line = String(trimmed.dropFirst().dropLast())
                        line = replacing(#"\s*\|\s*"#, in: line, with: "\t")
                            .trimmingCharacters(in: .whitespaces)
                    }
                }

                return insideFence ? line : cleanInlineSyntax(line)
            }

        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    private static func cleanInlineSyntax(_ value: String) -> String {
        var text = value
        text = replacing(#"!\[([^\]]*)\]\([^\)]*\)"#, in: text, with: "$1")
        text = replacing(#"\[([^\]]+)\]\([^\)]*\)"#, in: text, with: "$1")
        text = replacing(#"<((?:https?://|mailto:)[^>]+)>"#, in: text, with: "$1")
        text = replacing(#"`([^`\n]+)`"#, in: text, with: "$1")
        text = replacing(#"\*\*([^*\n]+)\*\*"#, in: text, with: "$1")
        text = replacing(#"__([^_\n]+)__"#, in: text, with: "$1")
        text = replacing(#"~~([^~\n]+)~~"#, in: text, with: "$1")
        text = replacing(#"(?<!\*)\*([^*\n]+)\*(?!\*)"#, in: text, with: "$1")
        text = replacing(#"(?<![\w])_([^_\n]+)_(?![\w])"#, in: text, with: "$1")
        text = replacing(#"\\([\\`*_{}\[\]()#+\-.!>])"#, in: text, with: "$1")
        return text
    }

    private static func replacing(
        _ pattern: String,
        in value: String,
        with replacement: String,
        caseInsensitive: Bool = false
    ) -> String {
        var options: String.CompareOptions = .regularExpression
        if caseInsensitive { options.insert(.caseInsensitive) }
        return value.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: options)
    }
}
