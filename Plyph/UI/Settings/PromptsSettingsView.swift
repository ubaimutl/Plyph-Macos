import SwiftUI

/// Built-in prompts and reusable prompt variables.
struct PromptsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPage(
            title: "Prompts",
            subtitle: "Adjust Plyph's built-in instructions and reusable variables."
        ) {
            builtInGroup
            variablesGroup
        }
    }

    private var builtInGroup: some View {
        SettingsSection(
            "Built-in prompts",
            subtitle: "Changes apply the next time the corresponding action runs."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                PromptEditor(
                    label: "Correction prompt", text: $settings.promptCorrect)
                Divider()
                PromptEditor(label: "Rewrite prompt", text: $settings.promptRewrite)
                Divider()
                PromptEditor(
                    label: "Run-prompt system guidance", text: $settings.promptRun)
            }
        }
    }

    private var variablesGroup: some View {
        SettingsSection(
            "Prompt variables",
            subtitle: "Use these values in any prompt without repeating them."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Language") {
                    TextField("Language", text: $settings.variableLanguage)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Tone") {
                    TextField("Tone", text: $settings.variableTone)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Style") {
                    TextField("Style", text: $settings.variableStyle)
                        .textFieldStyle(.roundedBorder)
                }
                Text(
                    "Available in prompts as ${language}, ${tone}, ${style}, and "
                        + "${selection}.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// Multi-line prompt editor row.
struct PromptEditor: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $text)
                .frame(minHeight: 64, maxHeight: 120)
                .font(.body)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }
    }
}
