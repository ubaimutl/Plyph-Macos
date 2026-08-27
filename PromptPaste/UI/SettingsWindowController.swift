import AppKit
import SwiftUI

/// Hosts the SwiftUI settings interface in a regular window. Only one window
/// instance exists; opening it again brings it to the front.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "PromptPaste Settings"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(
                rootView: SettingsRootView().environmentObject(SettingsStore.shared))
            self.window = window
        }
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        .padding()
    }
}
