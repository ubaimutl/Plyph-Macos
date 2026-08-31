import SwiftUI

enum ActionsSettingsPage: Equatable {
    case myActions
    case library
}

struct ActionsSettingsView: View {
    let page: ActionsSettingsPage

    @EnvironmentObject private var settings: SettingsStore
    @State private var editingAction: CustomAction?
    @State private var showEditor = false
    @State private var catalogSearch = ""
    @State private var catalogCategory: CatalogCategory?

    private let catalog = ActionCatalogStore.shared

    var body: some View {
        SettingsPage(title: pageTitle, subtitle: pageSubtitle) {
            if page == .myActions {
                runPromptGroup
                customActionsGroup
            } else {
                actionLibraryGroup
            }
        }
        .sheet(isPresented: $showEditor, onDismiss: { editingAction = nil }) {
            ActionEditorSheet(action: editingAction)
        }
    }

    private var pageTitle: String {
        page == .myActions ? "My Actions" : "Action Library"
    }

    private var pageSubtitle: String {
        page == .myActions
            ? "Create and configure the actions available throughout Plyph."
            : "Browse ready-made actions and add editable copies to your collection."
    }

    // MARK: Run selected prompt

    private var runPromptGroup: some View {
        SettingsSection(
            "Run selected prompt",
            subtitle: "Configure the action that treats selected text as an instruction."
        ) {
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
        }
    }

    // MARK: Custom actions

    private var customActionsGroup: some View {
        SettingsSection(
            "Custom actions",
            subtitle: "Enabled actions appear in menus and can be assigned as Quick Actions."
        ) {
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
        }
    }

    // MARK: Action Library

    private var actionLibraryGroup: some View {
        SettingsSection(
            "Browse actions",
            subtitle: "Catalog actions are bundled with Plyph and work entirely offline."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField("Search actions…", text: $catalogSearch)
                        .textFieldStyle(.roundedBorder)

                    Picker("Category", selection: $catalogCategory) {
                        Text("All Categories").tag(Optional<CatalogCategory>.none)
                        ForEach(CatalogCategory.allCases) { category in
                            Text(category.rawValue).tag(Optional(category))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                if catalog.actions.isEmpty {
                    Text("The bundled Action Library could not be loaded.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else if displayedCatalogActions.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundColor(.secondary)
                        Text("No Actions Found")
                            .font(.headline)
                        Text("Try another search or category.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                } else {
                    if showsFeaturedSection {
                        catalogSection(
                            title: "Featured",
                            actions: catalog.featuredActions)
                        Divider()
                    }

                    catalogSection(title: "Browse All", actions: displayedCatalogActions)
                }
            }
        }
    }

    private var displayedCatalogActions: [CatalogAction] {
        catalog.filtered(category: catalogCategory, search: catalogSearch)
    }

    private var showsFeaturedSection: Bool {
        catalogCategory == nil
            && catalogSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !catalog.featuredActions.isEmpty
    }

    private func catalogSection(title: String, actions: [CatalogAction]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 4)

            LazyVStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    catalogRow(action)
                    if index < actions.count - 1 {
                        Divider().padding(.leading, 30)
                    }
                }
            }
        }
    }

    private func catalogRow(_ action: CatalogAction) -> some View {
        let installed = catalog.isInstalled(action, in: settings.customActions)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: action.icon)
                .foregroundColor(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.name)
                    .fontWeight(.medium)
                Text(action.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Text(action.category.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 12)

            Button(installed ? "Added" : "Add") {
                catalog.install(actionID: action.id, in: settings)
            }
            .controlSize(.small)
            .disabled(installed)
            .frame(width: 62)
        }
        .padding(.vertical, 7)
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
