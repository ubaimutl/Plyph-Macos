import AppKit
import SwiftUI

/// Click-to-record shortcut field, mirroring the GNOME shortcut dialog
/// ("Press a key combination. Backspace clears it; Escape cancels.").
struct ShortcutRecorderField: View {
    @Binding var combo: HotKeyCombo

    var body: some View {
        ShortcutRecorderRepresentable(combo: $combo)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.gray.opacity(0.4))
            )
    }
}

struct ShortcutRecorderRepresentable: NSViewRepresentable {
    @Binding var combo: HotKeyCombo

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onCombo = { combo in
            Task { @MainActor in
                self.combo = combo
            }
        }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.currentCombo = combo
    }
}

/// AppKit control that captures a key combination when clicked.
final class ShortcutRecorderView: NSControl {
    var onCombo: ((HotKeyCombo) -> Void)?
    var currentCombo: HotKeyCombo = .none {
        didSet { updateLabel() }
    }

    private let label = NSTextField(labelWithString: "")
    private var recording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateLabel()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            recording = true
            updateLabel()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            recording = false
            updateLabel()
        }
        return resigned
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if recording {
            handleKey(event)
        } else {
            super.keyDown(with: event)
        }
    }

    private func handleKey(_ event: NSEvent) {
        let keyCode = event.keyCode
        let modifiers = HotKeyCombo.flags(from: event)

        if keyCode == 53 {  // Escape: cancel recording
            recording = false
            updateLabel()
            return
        }
        if keyCode == 51 && modifiers == 0 {  // Delete/Backspace: clear shortcut
            currentCombo = .none
            onCombo?(.none)
            recording = false
            updateLabel()
            return
        }
        // Require at least one modifier for single letters/digits to avoid
        // hijacking plain keys, except for function keys.
        let isFunctionKey = keyCode >= 122 && keyCode <= 140
        if modifiers == 0 && !isFunctionKey {
            NSSound.beep()
            return
        }
        let symbol = HotKeyCombo.symbol(
            for: keyCode, characters: event.charactersIgnoringModifiers)
        let next = HotKeyCombo(
            keyCode: keyCode, modifiers: modifiers, keySymbol: symbol)
        currentCombo = next
        onCombo?(next)
        recording = false
        updateLabel()
    }

    private func updateLabel() {
        if recording {
            label.stringValue = "Type shortcut…"
            layer?.backgroundColor =
                NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        } else {
            label.stringValue = currentCombo.displayOrEmpty.isEmpty
                ? "Not set" : currentCombo.displayString
            layer?.backgroundColor = nil
        }
    }
}
