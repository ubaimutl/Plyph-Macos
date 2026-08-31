import AppKit
import SwiftUI

/// A native one-line field that clips long values instead of turning into a
/// scrolling editor. Used for endpoints and credentials, where line breaks are
/// never valid input.
struct SingleLineField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var onCommit: (() -> Void)?

    init(
        _ placeholder: String,
        text: Binding<String>,
        secure: Bool = false,
        onCommit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
        self.onCommit = onCommit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.lineBreakMode = .byTruncatingTail
        (field.cell as? NSTextFieldCell)?.isScrollable = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SingleLineField

        init(parent: SingleLineField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onCommit?()
        }
    }
}
