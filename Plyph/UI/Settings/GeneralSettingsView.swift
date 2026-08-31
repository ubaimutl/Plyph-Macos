import SwiftUI
import UniformTypeIdentifiers

/// Core app behavior and permission state.
struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var accessibilityTrusted = AXAccess.isTrusted

    var body: some View {
        SettingsPage(
            title: "General",
            subtitle: "Choose how Plyph behaves when you work with selected text."
        ) {
            if !accessibilityTrusted {
                accessibilityNotice
            }
            behaviorGroup
            diagnosticsGroup
        }
        .onAppear { accessibilityTrusted = AXAccess.isTrusted }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXAccess.isTrusted
        }
    }

    private var accessibilityNotice: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission required")
                    .font(.headline)
                Text(
                    "Plyph needs Accessibility to read and replace selected text. "
                        + "Grant access in Privacy & Security settings, then reopen Plyph.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Open System Settings") {
                AXAccess.openSystemSettings()
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.65), lineWidth: 1)
        }
    }

    private var behaviorGroup: some View {
        SettingsSection("Behavior") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggleRow(
                    title: "Preview before replacing",
                    subtitle: "Review, edit, copy, or cancel generated text before it is inserted.",
                    isOn: $settings.previewResults)
                Divider()
                SettingsToggleRow(
                    title: "Use clipboard as a fallback",
                    subtitle: "Use previously copied text when Plyph cannot find a selection.",
                    isOn: $settings.clipboardFallback)
                Divider()
                SettingsToggleRow(
                    title: "Show action feedback",
                    subtitle: "Show progress in the originating toolbar or a stationary status bubble.",
                    isOn: $settings.pointerFeedback)
                Divider()
                SettingsToggleRow(
                    title: "Show selection toolbar",
                    subtitle: "Keep the P button beside selected text until you continue working elsewhere.",
                    isOn: $settings.selectionDotEnabled)
            }
        }
    }

    private var diagnosticsGroup: some View {
        SettingsSection(
            "Diagnostics",
            subtitle: "Troubleshooting information is stored locally on this Mac."
        ) {
            SettingsToggleRow(
                title: "Enable debug logging",
                subtitle: "Write diagnostic metadata to ~/Library/Logs/Plyph/debug.log.",
                isOn: $settings.enableDebugLogging)
        }
    }
}

struct ProviderSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPage(
            title: "AI Providers",
            subtitle: "Choose the service and model Plyph uses for its actions."
        ) {
            SettingsSection("Active provider") {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("Provider") {
                        Picker("Provider", selection: $settings.provider) {
                            ForEach(Providers.all, id: \.id) { provider in
                                Text(provider.name).tag(provider.id.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }
                    Divider()
                    ProviderSectionView(providerID: settings.provider)
                }
            }
        }
    }
}

struct ShortcutSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPage(
            title: "Shortcuts",
            subtitle: "Run frequent actions without opening the menu bar item."
        ) {
            SettingsSection("Global shortcuts") {
                VStack(alignment: .leading, spacing: 10) {
                    ShortcutRow(title: "Correct", binding: Binding(
                        get: { settings.correctShortcut },
                        set: { settings.correctShortcut = $0 }))
                    Divider()
                    ShortcutRow(title: "Rewrite", binding: Binding(
                        get: { settings.rewriteShortcut },
                        set: { settings.rewriteShortcut = $0 }))
                    Divider()
                    ShortcutRow(title: "Open actions", binding: Binding(
                        get: { settings.actionsShortcut },
                        set: { settings.actionsShortcut = $0 }))
                }
            }

            SettingsSection(
                "Action palette",
                subtitle: "Choose where the Open Actions shortcut displays its menu."
            ) {
                Picker("Position", selection: $settings.actionPalettePosition) {
                    Text("Do not show a palette").tag("disabled")
                    Text("Center of active screen").tag("monitor-center")
                    Text("Near pointer").tag("near-pointer")
                }
                .pickerStyle(.radioGroup)
            }
        }
    }
}

struct ApplicationsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPage(
            title: "Applications",
            subtitle: "Control where the selection toolbar is allowed to appear."
        ) {
            SettingsSection(
                "Excluded applications",
                subtitle: "Plyph never shows its selection toolbar in these apps."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    if settings.excludedAppIdentifierList.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "app.badge.checkmark")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("No applications excluded")
                                .fontWeight(.medium)
                            Text("The selection toolbar can appear in any supported app.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 100)
                    } else {
                        ForEach(settings.excludedAppIdentifierList, id: \.self) { identifier in
                            ExcludedAppRow(bundleIdentifier: identifier) {
                                settings.includeApp(bundleIdentifier: identifier)
                            }
                            if identifier != settings.excludedAppIdentifierList.last {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }

                    Divider()
                    Button(action: chooseApplicationsToExclude) {
                        Label("Add Application…", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func chooseApplicationsToExclude() {
        let panel = NSOpenPanel()
        panel.title = "Choose Applications to Exclude"
        panel.prompt = "Exclude"
        panel.message = "Plyph will not show its selection toolbar in the selected apps."
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let identifier = Bundle(url: url)?.bundleIdentifier {
                    settings.excludeApp(bundleIdentifier: identifier)
                }
            }
        }
    }
}

private struct ExcludedAppRow: View {
    let bundleIdentifier: String
    let remove: () -> Void

    private var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    private var displayName: String {
        guard let url = applicationURL else { return bundleIdentifier }
        return (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let url = applicationURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app.dashed")
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                Text(bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove from excluded apps")
        }
        .padding(.vertical, 5)
    }
}

/// One shortcut row: label plus a click-to-record recorder field.
struct ShortcutRow: View {
    let title: String
    @Binding var binding: HotKeyCombo

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ShortcutRecorderField(combo: $binding)
                .frame(width: 150, height: 26)
        }
    }
}
