import SwiftUI

/// The per-provider configuration rows shown under the provider picker:
/// endpoint/account fields, the Keychain-backed credential field, free-tier
/// notes, and the model picker with refresh and custom-model entry.
struct ProviderSectionView: View {
    let providerID: String

    var body: some View {
        let info = Providers.info(for: providerID) ?? Providers.all[0]
        VStack(alignment: .leading, spacing: 10) {
            if providerID == ProviderID.ollama.rawValue {
                OllamaSection()
            } else if providerID == ProviderID.cloudflare.rawValue {
                CloudflareSection()
            } else if info.requiresKey {
                CredentialField(providerID: providerID, label: info.credentialLabel)
            }

            if let note = info.freeUsageNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ModelPickerView(providerID: providerID)

            Label(
                "Larger models may use provider allowances faster or incur charges, "
                    + "depending on your account.",
                systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Ollama

struct OllamaSection: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SingleLineField("Address", text: $settings.ollamaURL)
            Text("Runs on your configured local server.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Cloudflare

struct CloudflareSection: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                SingleLineField("Account ID", text: $settings.cloudflareAccountID)
                Text("Required for Cloudflare Workers AI requests.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            CredentialField(
                providerID: ProviderID.cloudflare.rawValue, label: "API token")
        }
    }
}

// MARK: - Credential field (Keychain-backed)

/// Password field that loads from the Keychain on appear and saves on commit,
/// with a status indicator mirroring the GNOME secret entry.
struct CredentialField: View {
    let providerID: String
    let label: String

    @EnvironmentObject private var settings: SettingsStore
    @State private var draft = ""
    @State private var status: Status = .loading

    enum Status {
        case loading
        case saved
        case empty
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SingleLineField(label, text: $draft, secure: true, onCommit: save)
            HStack(spacing: 6) {
                switch status {
                case .loading:
                    ProgressView().controlSize(.small)
                    Text("Loading from Keychain…").font(.caption).foregroundColor(.secondary)
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Stored securely in the Keychain")
                        .font(.caption).foregroundColor(.secondary)
                case .empty:
                    Image(systemName: "key")
                    Text("No \(label) saved").font(.caption).foregroundColor(.secondary)
                case .error(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(message).font(.caption).foregroundColor(.secondary)
                }
            }
            Text("Press ⏎ to save. Values are stored in the macOS Keychain, never in plain files.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .task { await load() }
        .onChange(of: providerID) { _ in
            status = .loading
            Task { await load() }
        }
    }

    private func load() async {
        do {
            let stored = try KeychainStore.read(provider: providerID)
            draft = stored
            status = stored.isEmpty ? .empty : .saved
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func save() {
        Task {
            do {
                try KeychainStore.write(draft, provider: providerID)
                status = draft.trimmingCharacters(in: .whitespaces).isEmpty ? .empty : .saved
                _ = settings  // touch to keep environment used
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }
}

// MARK: - Model picker

/// Model picker with cached options, a refresh action that fetches the live
/// model list, and a custom-model sheet — mirroring the GNOME model row.
struct ModelPickerView: View {
    let providerID: String

    @EnvironmentObject private var settings: SettingsStore
    @State private var options: [ModelOption] = []
    @State private var statusText = ""
    @State private var isRefreshing = false
    @State private var showCustomSheet = false
    @State private var customDraft = ""

    private var info: ProviderInfo {
        Providers.info(for: providerID) ?? Providers.all[0]
    }

    private var currentModel: String {
        settings.model(for: providerID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Model", selection: Binding(
                    get: { currentModel },
                    set: { settings.setModel($0, for: providerID) }
                )) {
                    if currentModel.isEmpty {
                        Text("Choose a model").tag("")
                    }
                    ForEach(options) { option in
                        Text(displayName(option)).tag(option.id)
                    }
                    if !currentModel.isEmpty,
                        !options.contains(where: { $0.id == currentModel })
                    {
                        Text(currentModel).tag(currentModel)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Button(action: refresh) {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Refresh models")

                Button(action: openCustom) {
                    Image(systemName: "pencil")
                }
                .help("Enter a custom model")
            }

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            options = ModelCatalog.pickerOptions(
                provider: providerID, current: currentModel)
        }
        .onChange(of: providerID) { _ in
            options = ModelCatalog.pickerOptions(
                provider: providerID, current: settings.model(for: providerID))
            statusText = ""
        }
        .sheet(isPresented: $showCustomSheet) {
            customModelSheet
        }
    }

    private func displayName(_ option: ModelOption) -> String {
        option.name != option.id ? "\(option.name) — \(option.id)" : option.id
    }

    private func refresh() {
        isRefreshing = true
        statusText = "Loading…"
        let config = AiConfig.from(settings)
        Task {
            do {
                let models = try await ModelCatalog.fetchModels(
                    provider: providerID, config: config)
                ModelCatalog.cacheModels(models, provider: providerID)
                await MainActor.run {
                    options = models
                    statusText = models.isEmpty ? "No models found" : "\(models.count) available"
                    isRefreshing = false
                }
            } catch {
                await MainActor.run {
                    statusText = error.localizedDescription
                    isRefreshing = false
                }
            }
        }
    }

    private func openCustom() {
        customDraft = currentModel
        showCustomSheet = true
    }

    private var customModelSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom model").font(.headline)
            TextField("Model ID", text: $customDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showCustomSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = customDraft.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        settings.setModel(trimmed, for: providerID)
                        options = ModelCatalog.pickerOptions(
                            provider: providerID, current: trimmed)
                    }
                    showCustomSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
