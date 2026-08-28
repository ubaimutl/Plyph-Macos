import SwiftUI
import UniformTypeIdentifiers

/// General tab: active provider, shortcuts, and behavior settings.
struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var accessibilityTrusted = AXAccess.isTrusted

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                providerGroup
                if !accessibilityTrusted {
                    accessibilityNotice
                }
                shortcutsGroup
                behaviorGroup
                excludedAppsGroup
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { accessibilityTrusted = AXAccess.isTrusted }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXAccess.isTrusted
        }
    }

    private var providerGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Provider").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                Picker("Active provider", selection: $settings.provider) {
                    ForEach(Providers.all, id: \.id) { provider in
                        Text(provider.name).tag(provider.id.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                ProviderSectionView(providerID: settings.provider)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    private var accessibilityNotice: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility permission required")
                        .font(.headline)
                    Text(
                        "PromptPaste needs Accessibility to read the selected text and to "
                            + "replace it. Grant access in System Settings › Privacy & "
                            + "Security › Accessibility, then reopen PromptPaste.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Open System Settings") {
                    AXAccess.openSystemSettings()
                }
            }
            .padding(16)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange, lineWidth: 1))
        }
    }

    private var shortcutsGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcuts").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                ShortcutRow(
                    title: "Correct",
                    binding: Binding(
                        get: { settings.correctShortcut },
                        set: { settings.correctShortcut = $0 }))
                Divider()
                ShortcutRow(
                    title: "Rewrite",
                    binding: Binding(
                        get: { settings.rewriteShortcut },
                        set: { settings.rewriteShortcut = $0 }))
                Divider()
                ShortcutRow(
                    title: "Open actions",
                    binding: Binding(
                        get: { settings.actionsShortcut },
                        set: { settings.actionsShortcut = $0 }))
                Divider()
                Picker("Action palette", selection: $settings.actionPalettePosition) {
                    Text("Off").tag("disabled")
                    Text("Active screen center").tag("monitor-center")
                    Text("Near pointer").tag("near-pointer")
                }
                .pickerStyle(.menu)
                Text("Choose where the Open actions shortcut displays actions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    private var behaviorGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Behavior").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Preview before replacing", isOn: $settings.previewResults)
                Text("Confirm, copy, or cancel the generated result.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Divider()
                Toggle(
                    "Use clipboard when no text is selected",
                    isOn: $settings.clipboardFallback)
                Text("Allow actions to use previously copied text.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Divider()
                Toggle("Show feedback near pointer", isOn: $settings.pointerFeedback)
                Text("Show progress, success, and errors where you are working.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Divider()
                Toggle("Show action button near selected text", isOn: $settings.selectionDotEnabled)
                Text(
                    "A small floating button appears beside your selection. "
                        + "Click it to open the action list. Requires Accessibility permission.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Divider()
                Toggle("Enable debug logging", isOn: $settings.enableDebugLogging)
                Text("Write diagnostic metadata to ~/Library/Logs/PromptPaste/debug.log.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    private var excludedAppsGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Excluded apps").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Text("The selection button will never appear in these apps.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if settings.excludedAppIdentifierList.isEmpty {
                    Text("No apps excluded")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                } else {
                    VStack(spacing: 0) {
                        ForEach(settings.excludedAppIdentifierList, id: \.self) { identifier in
                            ExcludedAppRow(bundleIdentifier: identifier) {
                                settings.includeApp(bundleIdentifier: identifier)
                            }
                            if identifier != settings.excludedAppIdentifierList.last {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                }

                HStack {
                    Button {
                        chooseApplicationsToExclude()
                    } label: {
                        Label("Add Application…", systemImage: "plus")
                    }
                    Spacer()
                }
            }
            .padding(16)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    private func chooseApplicationsToExclude() {
        let panel = NSOpenPanel()
        panel.title = "Choose Applications to Exclude"
        panel.prompt = "Exclude"
        panel.message = "PromptPaste will not show its selection button in the selected apps."
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
