import AppKit
import SwiftUI

struct QuickActionsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var editingProfile: AppActionProfile?
    @State private var showProfileEditor = false

    var body: some View {
        SettingsPage(
            title: "Quick Actions",
            subtitle: "Choose the compact actions shown beside your text selection."
        ) {
            SettingsSection(
                "Default toolbar",
                subtitle: "These actions are used unless an application has its own profile."
            ) {
                QuickActionListEditor(actions: Binding(
                    get: { settings.quickActionConfiguration.actions },
                    set: { settings.quickActionConfiguration = QuickActionConfiguration(actions: $0) }))
            }

            SettingsSection(
                "Application profiles",
                subtitle: "Give individual apps a different Quick Actions arrangement."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if settings.appActionProfiles.isEmpty {
                        Text("No app-specific profiles.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(settings.appActionProfiles) { profile in
                        HStack(spacing: 10) {
                            AppIdentityView(bundleIdentifier: profile.bundleIdentifier)
                            Spacer()
                            Text("\(profile.actions.count) actions")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button {
                                editingProfile = profile
                                showProfileEditor = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .help("Edit profile")
                            Button {
                                settings.removeProfile(
                                    bundleIdentifier: profile.bundleIdentifier)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .help("Remove profile")
                        }
                        if profile.id != settings.appActionProfiles.last?.id {
                            Divider()
                        }
                    }
                    Divider()
                    Button {
                        editingProfile = nil
                        showProfileEditor = true
                    } label: {
                        Label("Add app profile", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showProfileEditor, onDismiss: { editingProfile = nil }) {
            AppProfileEditorSheet(profile: editingProfile)
                .environmentObject(settings)
        }
    }
}

struct QuickActionListEditor: View {
    @EnvironmentObject private var settings: SettingsStore
    @Binding var actions: [ActionReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, reference in
                HStack(spacing: 8) {
                    if let descriptor = ActionCatalog.descriptor(for: reference, settings: settings) {
                        Image(nsImage: descriptor.icon ?? NSImage())
                            .frame(width: 15, height: 15)
                        Text(descriptor.name)
                    } else {
                        Image(systemName: "questionmark.square.dashed")
                        Text("Unavailable action")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { move(index, by: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    Button { move(index, by: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == actions.count - 1)
                    Button { actions.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .help("Remove from Quick Actions")
                }
                if index < actions.count - 1 { Divider() }
            }

            if actions.count < QuickActionConfiguration.maximumCount {
                Menu {
                    ForEach(availableDescriptors) { descriptor in
                        Button(descriptor.name) {
                            actions.append(descriptor.reference)
                            actions = QuickActionConfiguration.normalized(actions)
                        }
                    }
                } label: {
                    Label("Add quick action", systemImage: "plus")
                }
                .disabled(availableDescriptors.isEmpty)
            }
            Text("Up to four actions appear beside the selection button. More remains available in •••.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var availableDescriptors: [ActionDescriptor] {
        settings.availableActionDescriptors.filter { !actions.contains($0.reference) }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard actions.indices.contains(index), actions.indices.contains(target) else { return }
        actions.swapAt(index, target)
    }
}

private struct AppProfileEditorSheet: View {
    let profile: AppActionProfile?
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var bundleIdentifier = ""
    @State private var actions: [ActionReference] = QuickActionConfiguration.default.actions

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return !id.isEmpty
                    && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(profile == nil ? "Add app profile" : "Edit app profile")
                .font(.headline)

            Picker("Running app", selection: $bundleIdentifier) {
                Text("Choose an app…").tag("")
                ForEach(runningApps, id: \.processIdentifier) { app in
                    Text(app.localizedName ?? app.bundleIdentifier ?? "Application")
                        .tag(app.bundleIdentifier ?? "")
                }
            }
            .pickerStyle(.menu)

            TextField("Bundle identifier", text: $bundleIdentifier)
                .textFieldStyle(.roundedBorder)

            QuickActionListEditor(actions: $actions)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bundleIdentifier.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            guard let profile else { return }
            bundleIdentifier = profile.bundleIdentifier
            actions = profile.actions
        }
    }

    private func save() {
        if let oldID = profile?.bundleIdentifier,
           oldID.caseInsensitiveCompare(bundleIdentifier) != .orderedSame {
            settings.removeProfile(bundleIdentifier: oldID)
        }
        settings.setProfile(AppActionProfile(
            bundleIdentifier: bundleIdentifier,
            actions: actions))
        dismiss()
    }
}

private struct AppIdentityView: View {
    let bundleIdentifier: String
    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(appURL?.deletingPathExtension().lastPathComponent ?? bundleIdentifier)
                Text(bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
