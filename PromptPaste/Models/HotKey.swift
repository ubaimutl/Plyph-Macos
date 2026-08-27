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
        if modifiers & HotKeyCombo.controlFlag != 0 { mask |= UInt32(controlKey) }
        if modifiers & HotKeyCombo.shiftFlag != 0 { mask |= UInt32(shiftKey) }
        if modifiers & HotKeyCombo.optionFlag != 0 { mask |= UInt32(optionKey) }
        if modifiers & HotKeyCombo.commandFlag != 0 { mask |= UInt32(cmdKey) }
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
        if modifiers & UInt(controlFlag) != 0 { text += "⌃" }
        if modifiers & UInt(shiftFlag) != 0 { text += "⇧" }
        if modifiers & UInt(optionFlag) != 0 { text += "⌥" }
        if modifiers & UInt(commandFlag) != 0 { text += "⌘" }
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
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
        ]
        for (code, symbol) in letters { table[code] = symbol }
        let digits: [(UInt16, String)] = [
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
            (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
            (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        ]
        for (code, symbol) in digits { table[code] = symbol }
        table[kVK_Space] = "Space"
        table[kVK_Return] = "↩"
        table[kVK_Tab] = "⇥"
        table[kVK_Escape] = "⎋"
        table[kVK_Delete] = "⌫"
        table[kVK_ForwardDelete] = "⌦"
        table[kVK_LeftArrow] = "←"
        table[kVK_RightArrow] = "→"
        table[kVK_UpArrow] = "↑"
        table[kVK_DownArrow] = "↓"
        table[kVK_Home] = "↖"
        table[kVK_End] = "↘"
        table[kVK_PageUp] = "⇞"
        table[kVK_PageDown] = "⇟"
        for index in 0..<19 {
            table[UInt16(kVK_F1 + index)] = "F\(index + 1)"
        }
        table[kVK_ANSI_Minus] = "-"
        table[kVK_ANSI_Equal] = "="
        table[kVK_ANSI_LeftBracket] = "["
        table[kVK_ANSI_RightBracket] = "]"
        table[kVK_ANSI_Semicolon] = ";"
        table[kVK_ANSI_Quote] = "'"
        table[kVK_ANSI_Comma] = ","
        table[kVK_ANSI_Period] = "."
        table[kVK_ANSI_Slash] = "/"
        table[kVK_ANSI_Backslash] = "\\"
        table[kVK_ANSI_Grave] = "`"
        return table
    }()
}
