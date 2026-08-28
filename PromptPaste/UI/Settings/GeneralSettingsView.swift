import SwiftUI

/// General tab: active provider, shortcuts, and behavior settings.
struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var accessibilityTrusted = AXAccess.isTrusted

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                providerGroup
                if !accessibilityTrusted {
                    accessibilityNotice
                }
                shortcutsGroup
                behaviorGroup
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { accessibilityTrusted = AXAccess.isTrusted }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityTrusted = AXAccess.isTrusted
        }
    }

    private var providerGroup: some View {
        GroupBox {
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
            .padding(4)
        } label: {
            Text("Provider")
        }
    }

    private var accessibilityNotice: some View {
        GroupBox {
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
            .padding(4)
        }
    }

    private var shortcutsGroup: some View {
        GroupBox {
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
            .padding(4)
        } label: {
            Text("Shortcuts")
        }
    }

    private var behaviorGroup: some View {
        GroupBox {
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
            }
            .padding(4)
        } label: {
            Text("Behavior")
        }
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
