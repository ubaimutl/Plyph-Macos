import XCTest
@testable import Plyph

final class CustomActionTests: XCTestCase {
    func testStarterActionsAreValidAndUseStableIDs() {
        XCTAssertEqual(CustomAction.starterActions.count, 3)
        XCTAssertTrue(CustomAction.starterActions.allSatisfy(\.isValid))
        XCTAssertEqual(
            CustomAction.starterActions.map(\.id),
            ["starter-summarize-v1", "starter-translate-v1", "starter-tone-v1"])
        XCTAssertTrue(CustomAction.starterActions[1].prompt.contains("${language}"))
        XCTAssertTrue(CustomAction.starterActions[2].prompt.contains("${tone}"))
    }

    func testDecodeGNOMEShapedJSONWithDefaults() throws {
        // enabled omitted → true, limits invalid → 0, unknown mode → transform
        let json = """
        [
          {"id": "a", "name": "Fix it", "prompt": "Fix ${selection}",
           "inputLimit": -3, "outputLimit": 0},
          {"id": "b", "name": "Ask", "prompt": "Answer briefly",
           "enabled": false, "inputMode": "prompt",
           "provider": "openai", "model": "gpt-4.1-mini",
           "inputLimit": 4000, "outputLimit": 1000}
        ]
        """
        let actions = CustomActionStore.decode(json)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].enabled, true)
        XCTAssertEqual(actions[0].inputMode, .transform)
        XCTAssertEqual(actions[0].inputLimit, 0)
        XCTAssertEqual(actions[1].enabled, false)
        XCTAssertEqual(actions[1].inputMode, .prompt)
        XCTAssertEqual(actions[1].provider, "openai")
        XCTAssertEqual(actions[1].model, "gpt-4.1-mini")
        XCTAssertEqual(actions[1].inputLimit, 4000)
        XCTAssertEqual(actions[1].outputLimit, 1000)
    }

    func testDecodeFiltersInvalidActions() {
        // Missing name, or transform mode with empty prompt, are dropped
        // (actions.js parity).
        let json = """
        [
          {"id": "1", "name": "  ", "prompt": "x"},
          {"id": "2", "name": "No prompt", "prompt": "   "},
          {"id": "3", "name": "Prompt mode ok", "prompt": "", "inputMode": "prompt"}
        ]
        """
        let actions = CustomActionStore.decode(json)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].id, "3")
    }

    func testRoundTripThroughEncode() {
        let action = CustomAction(
            name: "Translate", prompt: "Translate ${selection} to ${language}",
            enabled: true, provider: "groq", model: "llama-3", inputMode: .transform,
            inputLimit: 8000, outputLimit: 2000)
        let decoded = CustomActionStore.decode(CustomActionStore.encode([action]))
        XCTAssertEqual(decoded, [action])
    }

    func testSummarySubtitle() {
        let action = CustomAction(
            name: "T", prompt: "p", provider: "", inputLimit: 2000, outputLimit: 0)
        let subtitle = action.summarySubtitle
        XCTAssertTrue(subtitle.contains("Uses active provider and model"))
        XCTAssertTrue(subtitle.contains("input 2K"))
        XCTAssertTrue(subtitle.contains("output Auto"))
    }

    func testFormatTokenLimit() {
        XCTAssertEqual(CustomAction.formatTokenLimit(0), "Auto")
        XCTAssertEqual(CustomAction.formatTokenLimit(2000), "2K")
        XCTAssertEqual(CustomAction.formatTokenLimit(1500), "1500")
    }

    func testPromptPreviewTruncates() {
        let long = String(repeating: "a", count: 200)
        let preview = CustomAction.promptPreview(long)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertLessThan(preview.count, 200)
    }
}
