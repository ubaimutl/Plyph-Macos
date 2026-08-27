import AppKit
import Carbon.HIToolbox
import Foundation

/// A keyboard shortcut combination, stored as JSON in the shortcuts settings
/// (`correct-shortcut`, `rewrite-shortcut`, `actions-shortcut`).
/// `keyCode` is a Carbon virtual keycode; `modifiers` uses
/// `NSEvent.ModifierFlags.rawValue` bits.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    /// Human-readable key name captured when the shortcut was recorded.
    var keySymbol: String

    init(keyCode: UInt16 = 0, modifiers: UInt = 0, keySymbol: String = "") {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keySymbol = keySymbol
    }

    var isEmpty: Bool { keyCode == 0 && modifiers == 0 }
    static let none = HotKeyCombo()

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(keySymbol, forKey: .keySymbol)
    }

    enum CodingKeys: String, CodingKey {
        case keyCode, modifiers
        case keySymbol
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = try container.decode(UInt.self, forKey: .modifiers)
        keySymbol = try container.decodeIfPresent(String.self, forKey: .keySymbol) ?? ""
    }

    /// Carbon modifier mask for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers & UInt(HotKeyCombo.controlFlag) != 0 { mask |= UInt32(controlKey) }
        if modifiers & UInt(HotKeyCombo.shiftFlag) != 0 { mask |= UInt32(shiftKey) }
        if modifiers & UInt(HotKeyCombo.optionFlag) != 0 { mask |= UInt32(optionKey) }
        if modifiers & UInt(HotKeyCombo.commandFlag) != 0 { mask |= UInt32(cmdKey) }
        return mask
    }

    static let controlFlag = 1 << 0
    static let shiftFlag = 1 << 1
    static let optionFlag = 1 << 2
    static let commandFlag = 1 << 3

    /// Converts `NSEvent.ModifierFlags` (minus irrelevant bits) into our own bits.
    static func flags(from event: NSEvent) -> UInt {
        let flags = event.modifierFlags
        var mask: UInt = 0
        if flags.contains(.control) { mask |= UInt(controlFlag) }
        if flags.contains(.shift) { mask |= UInt(shiftFlag) }
        if flags.contains(.option) { mask |= UInt(optionFlag) }
        if flags.contains(.command) { mask |= UInt(commandFlag) }
        return mask
    }

    /// Symbol-only representation, e.g. "⌘⇧C".
    var displayString: String {
        guard !isEmpty else { return "" }
        var text = ""
        if modifiers & UInt(Self.controlFlag) != 0 { text += "⌃" }
        if modifiers & UInt(Self.shiftFlag) != 0 { text += "⇧" }
        if modifiers & UInt(Self.optionFlag) != 0 { text += "⌥" }
        if modifiers & UInt(Self.commandFlag) != 0 { text += "⌘" }
        text += keySymbol.isEmpty ? "Key \(keyCode)" : keySymbol
        return text
    }

    /// A usable default description when nothing is set.
    var displayOrEmpty: String { isEmpty ? "" : displayString }

    /// JSON representation used in UserDefaults; empty string means "not set".
    var jsonString: String {
        guard !isEmpty else { return "" }
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func from(jsonString: String) -> HotKeyCombo {
        guard let data = jsonString.data(using: .utf8),
            let combo = try? JSONDecoder().decode(HotKeyCombo.self, from: data),
            !combo.isEmpty
        else { return .none }
        return combo
    }

    /// Maps common Carbon virtual keycodes to display symbols.
    static func symbol(for keyCode: UInt16, characters: String?) -> String {
        if let characters, characters.count == 1 {
            let upper = characters.uppercased()
            if upper.range(of: "[A-Z0-9]", options: .regularExpression) != nil {
                return upper
            }
        }
        return symbolTable[keyCode] ?? "Key \(keyCode)"
    }

    private static let symbolTable: [UInt16: String] = {
        var table: [UInt16: String] = [:]
        let letters: [(UInt16, String)] = [
            (UInt16(kVK_ANSI_A), "A"), (UInt16(kVK_ANSI_B), "B"), (UInt16(kVK_ANSI_C), "C"), (UInt16(kVK_ANSI_D), "D"),
            (UInt16(kVK_ANSI_E), "E"), (UInt16(kVK_ANSI_F), "F"), (UInt16(kVK_ANSI_G), "G"), (UInt16(kVK_ANSI_H), "H"),
            (UInt16(kVK_ANSI_I), "I"), (UInt16(kVK_ANSI_J), "J"), (UInt16(kVK_ANSI_K), "K"), (UInt16(kVK_ANSI_L), "L"),
            (UInt16(kVK_ANSI_M), "M"), (UInt16(kVK_ANSI_N), "N"), (UInt16(kVK_ANSI_O), "O"), (UInt16(kVK_ANSI_P), "P"),
            (UInt16(kVK_ANSI_Q), "Q"), (UInt16(kVK_ANSI_R), "R"), (UInt16(kVK_ANSI_S), "S"), (UInt16(kVK_ANSI_T), "T"),
            (UInt16(kVK_ANSI_U), "U"), (UInt16(kVK_ANSI_V), "V"), (UInt16(kVK_ANSI_W), "W"), (UInt16(kVK_ANSI_X), "X"),
            (UInt16(kVK_ANSI_Y), "Y"), (UInt16(kVK_ANSI_Z), "Z"),
        ]
        for (code, symbol) in letters { table[code] = symbol }
        let digits: [(UInt16, String)] = [
            (UInt16(kVK_ANSI_0), "0"), (UInt16(kVK_ANSI_1), "1"), (UInt16(kVK_ANSI_2), "2"), (UInt16(kVK_ANSI_3), "3"),
            (UInt16(kVK_ANSI_4), "4"), (UInt16(kVK_ANSI_5), "5"), (UInt16(kVK_ANSI_6), "6"), (UInt16(kVK_ANSI_7), "7"),
            (UInt16(kVK_ANSI_8), "8"), (UInt16(kVK_ANSI_9), "9"),
        ]
        for (code, symbol) in digits { table[code] = symbol }
        table[UInt16(kVK_Space)] = "Space"
        table[UInt16(kVK_Return)] = "↩"
        table[UInt16(kVK_Tab)] = "⇥"
        table[UInt16(kVK_Escape)] = "⎋"
        table[UInt16(kVK_Delete)] = "⌫"
        table[UInt16(kVK_ForwardDelete)] = "⌦"
        table[UInt16(kVK_LeftArrow)] = "←"
        table[UInt16(kVK_RightArrow)] = "→"
        table[UInt16(kVK_UpArrow)] = "↑"
        table[UInt16(kVK_DownArrow)] = "↓"
        table[UInt16(kVK_Home)] = "↖"
        table[UInt16(kVK_End)] = "↘"
        table[UInt16(kVK_PageUp)] = "⇞"
        table[UInt16(kVK_PageDown)] = "⇟"
        for index in 0..<19 {
            table[UInt16(kVK_F1 + index)] = "F\(index + 1)"
        }
        table[UInt16(kVK_ANSI_Minus)] = "-"
        table[UInt16(kVK_ANSI_Equal)] = "="
        table[UInt16(kVK_ANSI_LeftBracket)] = "["
        table[UInt16(kVK_ANSI_RightBracket)] = "]"
        table[UInt16(kVK_ANSI_Semicolon)] = ";"
        table[UInt16(kVK_ANSI_Quote)] = "'"
        table[UInt16(kVK_ANSI_Comma)] = ","
        table[UInt16(kVK_ANSI_Period)] = "."
        table[UInt16(kVK_ANSI_Slash)] = "/"
        table[UInt16(kVK_ANSI_Backslash)] = "\\"
        table[UInt16(kVK_ANSI_Grave)] = "`"
        return table
    }()
}
