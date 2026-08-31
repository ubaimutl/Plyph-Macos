import XCTest
@testable import Plyph

final class HotKeyTests: XCTestCase {
    func testDisplayString() {
        let combo = HotKeyCombo(
            keyCode: 8, modifiers: UInt(HotKeyCombo.commandFlag | HotKeyCombo.shiftFlag),
            keySymbol: "C")
        XCTAssertEqual(combo.displayString, "⌘⇧C")
    }

    func testDisplayStringOrderControlShiftOptionCommand() {
        let combo = HotKeyCombo(
            keyCode: 8,
            modifiers: UInt(
                HotKeyCombo.controlFlag | HotKeyCombo.shiftFlag
                    | HotKeyCombo.optionFlag | HotKeyCombo.commandFlag),
            keySymbol: "C")
        XCTAssertEqual(combo.displayString, "⌃⇧⌥⌘C")
    }

    func testJSONRoundTrip() {
        let combo = HotKeyCombo(
            keyCode: 15, modifiers: UInt(HotKeyCombo.controlFlag | HotKeyCombo.optionFlag),
            keySymbol: "R")
        let restored = HotKeyCombo.from(jsonString: combo.jsonString)
        XCTAssertEqual(restored, combo)
    }

    func testEmptyJSONMeansUnset() {
        XCTAssertEqual(HotKeyCombo.none.jsonString, "")
        XCTAssertEqual(HotKeyCombo.from(jsonString: ""), HotKeyCombo.none)
        XCTAssertEqual(HotKeyCombo.from(jsonString: "not json"), HotKeyCombo.none)
    }

    func testCarbonModifiers() {
        let combo = HotKeyCombo(
            keyCode: 8, modifiers: UInt(HotKeyCombo.commandFlag | HotKeyCombo.optionFlag),
            keySymbol: "C")
        // cmdKey = 1 << 8 (256), optionKey = 1 << 11 (2048)
        XCTAssertEqual(combo.carbonModifiers, UInt32(256 | 2048))
    }
}
