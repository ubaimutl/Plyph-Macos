import SwiftUI

/// Actions tab: the "Run selected prompt" overrides and the custom actions
/// list (enable/disable, reorder, edit, add) — mirroring the GNOME Actions page.
struct ActionsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var editingAction: CustomAction?
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                runPromptGroup
                customActionsGroup
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showEditor, onDismiss: { editingAction = nil }) {
            ActionEditorSheet(action: editingAction)
        }
    }

    // MARK: Run selected prompt

    private var runPromptGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Provider override", selection: $settings.promptRunProvider) {
                    Text("Use active provider").tag("")
                    ForEach(Providers.all, id: \.id) { provider in
                        Text(provider.name).tag(provider.id.rawValue)
                    }
                }
                .pickerStyle(.menu)

                TextField(
                    "Model override (optional)",
                    text: $settings.promptRunModel
                )
                .textFieldStyle(.roundedBorder)
                .disabled(settings.promptRunProvider.isEmpty)

                Text("Selected text is sent directly as the user instruction.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TokenLimitPicker(
                    title: "Input limit",
                    subtitle:
                        "Stops before sending when the selected prompt is over this estimate.",
                    presets: TokenLimitPicker.inputPresets,
                    binding: $settings.promptRunInputLimit)
                TokenLimitPicker(
                    title: "Output limit",
                    subtitle: "Auto allows responses up to 2000 tokens.",
                    presets: TokenLimitPicker.outputPresets,
                    binding: $settings.promptRunOutputLimit)
            }
            .padding(4)
        } label: {
            Text("Run selected prompt")
        }
    }

    // MARK: Custom actions

    private var customActionsGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if settings.customActions.isEmpty {
                    Text("No custom actions yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(Array(settings.customActions.enumerated()), id: \.element.id) {
                    index, action in
                    HStack(alignment: .center, spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { settings.customActions.first { $0.id == action.id }?.enabled ?? false },
                            set: { value in
                                if let index = settings.customActions.firstIndex(
                                    where: { $0.id == action.id })
                                {
                                    settings.customActions[index].enabled = value
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("Show in panel menu")

                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.name)
                                .font(.headline)
                            Text(action.summarySubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(4)
                        }
                        Spacer()

                        Button {
                            moveAction(id: action.id, offset: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .help("Move up")

                        Button {
                            moveAction(id: action.id, offset: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == settings.customActions.count - 1)
                        .help("Move down")

                        Button {
                            editingAction = action
                            showEditor = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .help("Edit action")
                    }
                    if index < settings.customActions.count - 1 {
                        Divider()
                    }
                }

                Divider()
                Button {
                    editingAction = nil
                    showEditor = true
                } label: {
                    Label("Add action", systemImage: "plus")
                }
            }
            .padding(4)
        } label: {
            Text("Custom actions")
        }
    }

    private func moveAction(id: String, offset: Int) {
        guard let index = settings.customActions.firstIndex(where: { $0.id == id }) else {
            return
        }
        let target = index + offset
        guard target >= 0, target < settings.customActions.count else { return }
        settings.customActions.swapAt(index, target)
    }
}
