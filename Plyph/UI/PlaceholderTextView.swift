import AppKit

/// NSTextView does not provide AppKit's placeholder API, so multiline inputs
/// use this small native subclass to draw one without inserting fake content.
final class PlaceholderTextView: NSTextView {
    var placeholderString: String? {
        didSet { needsDisplay = true }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty,
              let placeholderString,
              !placeholderString.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let linePadding = textContainer?.lineFragmentPadding ?? 0
        placeholderString.draw(
            at: NSPoint(
                x: textContainerInset.width + linePadding,
                y: textContainerInset.height),
            withAttributes: attributes)
    }
}
