import AppKit
import SwiftUI

/// Hosts the SwiftUI settings interface in a regular window. Plyph is
/// normally a menu-bar utility, so opening a regular window temporarily shows
/// the app in the Dock and closing the last regular window hides it again.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        // A real app window should behave like a normal macOS application:
        // show Plyph in the Dock while the window is open.
        NSApp.setActivationPolicy(.regular)

        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 650),
                styleMask: [.titled, .closable, .miniaturizable, .resizable,
                            .unifiedTitleAndToolbar, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Plyph Settings"
            window.subtitle = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: 780, height: 540)
            window.isReleasedWhenClosed = false
            window.delegate = self
            let restoredFrame = window.setFrameUsingName("PlyphSettingsWindow")
            window.setFrameAutosaveName("PlyphSettingsWindow")
            if !restoredFrame { window.center() }
            window.contentView = NSHostingView(
                rootView: SettingsRootView().environmentObject(SettingsStore.shared))
            self.window = window
        }

        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Wait until AppKit has actually hidden the closing window before
        // deciding whether any other normal Plyph window still exists.
        DispatchQueue.main.async {
            let hasVisibleRegularWindow = NSApp.windows.contains { candidate in
                candidate.isVisible
                    && !(candidate is NSPanel)
                    && candidate.styleMask.contains(.titled)
            }

            if !hasVisibleRegularWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

private enum SettingsDestination: String, CaseIterable, Hashable, Identifiable {
    case general
    case providers
    case shortcuts
    case quickActions
    case myActions
    case library
    case prompts
    case applications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .providers: return "AI Providers"
        case .shortcuts: return "Shortcuts"
        case .quickActions: return "Quick Actions"
        case .myActions: return "My Actions"
        case .library: return "Action Library"
        case .prompts: return "Prompts"
        case .applications: return "Applications"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .providers: return "cpu"
        case .shortcuts: return "command"
        case .quickActions: return "bolt"
        case .myActions: return "slider.horizontal.3"
        case .library: return "square.grid.2x2"
        case .prompts: return "text.quote"
        case .applications: return "app.badge"
        }
    }
}

struct SettingsRootView: View {
    @State private var selection: SettingsDestination? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Settings") {
                    destinationRow(.general)
                    destinationRow(.providers)
                    destinationRow(.shortcuts)
                }
                Section("Actions") {
                    destinationRow(.quickActions)
                    destinationRow(.myActions)
                    destinationRow(.library)
                }
                Section("Configuration") {
                    destinationRow(.prompts)
                    destinationRow(.applications)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 540)
    }

    private func destinationRow(_ destination: SettingsDestination) -> some View {
        Label(destination.title, systemImage: destination.icon)
            .tag(destination)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettingsView()
        case .providers:
            ProviderSettingsView()
        case .shortcuts:
            ShortcutSettingsView()
        case .quickActions:
            QuickActionsSettingsView()
        case .myActions:
            ActionsSettingsView(page: .myActions)
        case .library:
            ActionsSettingsView(page: .library)
        case .prompts:
            PromptsSettingsView()
        case .applications:
            ApplicationsSettingsView()
        }
    }
}
