import SwiftUI

/// Prompts tab: the built-in prompts and the prompt variables
/// (${language}, ${tone}, ${style}, ${selection}).
struct PromptsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                builtInGroup
                variablesGroup
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var builtInGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                PromptEditor(
                    label: "Correction prompt", text: $settings.promptCorrect)
                Divider()
                PromptEditor(label: "Rewrite prompt", text: $settings.promptRewrite)
                Divider()
                PromptEditor(
                    label: "Run-prompt system guidance", text: $settings.promptRun)
            }
            .padding(4)
        } label: {
            Text("Built-in prompts")
        }
    }

    private var variablesGroup: some View {
        GroupBox {
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
            .padding(4)
        } label: {
            Text("Prompt variables")
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
                .border(Color.gray.opacity(0.3))
        }
    }
}
