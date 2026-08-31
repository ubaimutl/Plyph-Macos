import SwiftUI

/// Editor for creating or editing a custom action: name, input mode, prompt
/// (transformation prompt or optional system guidance), provider/model
/// overrides, token limits and visibility — mirroring the GNOME editor dialog,
/// including its validation rules.
struct ActionEditorSheet: View {
    let action: CustomAction?

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var inputMode: InputMode = .transform
    @State private var prompt = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var inputLimit = 0
    @State private var outputLimit = 0
    @State private var outputBehavior = ActionOutputBehavior.preview
    @State private var visibilityConditions: [ActionVisibilityCondition] = []
    @State private var enabled = true
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action == nil ? "New action" : "Edit action")
                .font(.headline)

            Form {
                TextField("Name", text: $name)

                Picker("Input mode", selection: $inputMode) {
                    Text("Transform selected text").tag(InputMode.transform)
                    Text("Use selected text as prompt").tag(InputMode.prompt)
                }
                .pickerStyle(.menu)
                Text(
                    inputMode == .prompt
                        ? "The selection is sent as the user instruction."
                        : "The selection is transformed according to the prompt.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(inputMode == .prompt
                        ? "System guidance (optional)"
                        : "Transformation prompt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $prompt)
                        .frame(minHeight: 90, maxHeight: 160)
                        .font(.body)
                        .border(Color.gray.opacity(0.3))
                }

                Picker("Provider override", selection: $provider) {
                    Text("Use active provider").tag("")
                    ForEach(Providers.all, id: \.id) { info in
                        Text(info.name).tag(info.id.rawValue)
                    }
                }
                .pickerStyle(.menu)

                TextField("Model override (optional)", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .disabled(provider.isEmpty)

                TokenLimitPicker(
                    title: "Input limit",
                    subtitle:
                        "Stops before sending when the selected text is over this estimate.",
                    presets: TokenLimitPicker.inputPresets,
                    binding: $inputLimit)
                TokenLimitPicker(
                    title: "Output limit",
                    subtitle: "Sets the maximum response length for this action.",
                    presets: TokenLimitPicker.outputPresets,
                    binding: $outputLimit)

                Picker("Output", selection: $outputBehavior) {
                    ForEach(ActionOutputBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .pickerStyle(.menu)

                VisibilityConditionsEditor(conditions: $visibilityConditions)

                Toggle("Show in panel menu", isOn: $enabled)
            }

            if let message = validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                if action != nil {
                    Button("Delete", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog(
            "Delete this action?", isPresented: $showDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let action {
                    settings.customActions.removeAll { $0.id == action.id }
                }
                dismiss()
            }
        }
    }

    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "A name is required."
        }
        if inputMode == .transform
            && prompt.trimmingCharacters(in: .whitespaces).isEmpty
        {
            return "A transformation prompt is required."
        }
        if inputLimit < 0 || outputLimit < 0 {
            return "Limits must be positive numbers."
        }
        return nil
    }

    private func load() {
        guard let action else { return }
        name = action.name
        inputMode = action.inputMode
        prompt = action.prompt
        provider = action.provider
        model = action.model
        inputLimit = action.inputLimit
        outputLimit = action.outputLimit
        outputBehavior = action.outputBehavior
        visibilityConditions = action.visibilityConditions
        enabled = action.enabled
    }

    private func save() {
        var next = action ?? CustomAction(name: name, prompt: prompt)
        next.name = name.trimmingCharacters(in: .whitespaces)
        next.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        next.inputMode = inputMode
        next.provider = provider
        next.model = provider.isEmpty ? "" : model.trimmingCharacters(in: .whitespaces)
        next.inputLimit = CustomAction.sanitizeLimit(inputLimit)
        next.outputLimit = CustomAction.sanitizeLimit(outputLimit)
        next.outputBehavior = outputBehavior
        next.visibilityConditions = visibilityConditions.filter { $0 != .always }
        next.enabled = enabled

        if let index = settings.customActions.firstIndex(where: { $0.id == next.id }) {
            settings.customActions[index] = next
        } else {
            settings.customActions.append(next)
        }
        dismiss()
    }
}
