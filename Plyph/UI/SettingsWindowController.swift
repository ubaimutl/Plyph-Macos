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
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable,
                            .unifiedTitleAndToolbar],
                backing: .buffered, defer: false)
            window.title = "Plyph"
            window.subtitle = "Settings"
            window.titlebarAppearsTransparent = false
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
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

/// The settings tabs, mirroring the GNOME preferences pages:
/// General / Actions / Prompts.
struct SettingsRootView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ActionsSettingsView()
                .tabItem { Label("Actions", systemImage: "list.bullet") }
            PromptsSettingsView()
                .tabItem { Label("Prompts", systemImage: "doc.text") }
        }
        .frame(minWidth: 740, minHeight: 540)
    }
}
