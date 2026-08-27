import AppKit
import Foundation

/// A snapshot of the pasteboard contents so the user's clipboard can be
/// restored after the explicit-copy capture or a paste-based replacement.
struct ClipboardSnapshot {
    /// Serializable copy of every pasteboard item's data.
    let items: [[NSPasteboard.PasteboardType: Data]]
    /// Pasteboard text at snapshot time (used for the clipboard-fallback).
    let string: String
}

/// Pasteboard helpers: snapshot/restore, change detection via `changeCount`,
/// and string write/read. Nothing here relies on fixed sleeps for correctness;
/// consumers wait on `changeCount` transitions.
enum ClipboardStore {
    static var changeCount: Int {
        NSPasteboard.general.changeCount
    }

    static func currentString() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    static func clear() {
        NSPasteboard.general.clearContents()
    }

    static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Captures the pasteboard contents. Returns nil when the pasteboard is empty.
    static func snapshot() -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        let string = pasteboard.string(forType: .string) ?? ""
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let bytes = item.data(forType: type) {
                    data[type] = bytes
                }
            }
            if !data.isEmpty {
                items.append(data)
            }
        }
        if items.isEmpty && string.isEmpty {
            return nil
        }
        return ClipboardSnapshot(items: items, string: string)
    }

    /// Restores a snapshot. Best effort: types that cannot be serialized are skipped.
    static func restore(_ snapshot: ClipboardSnapshot?) {
        guard let snapshot else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if snapshot.items.isEmpty {
            return
        }
        for stored in snapshot.items {
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: type)
            }
            pasteboard.writeObject(item)
        }
    }
}
