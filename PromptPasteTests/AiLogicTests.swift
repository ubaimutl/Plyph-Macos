import XCTest
@testable import PromptPaste

final class AiLogicTests: XCTestCase {
    // MARK: Token math (GNOME parity)

    func testEstimateTokens() {
        XCTAssertEqual(AiClient.estimateTokens(""), 0)
        XCTAssertEqual(AiClient.estimateTokens("abcd"), 1)
        XCTAssertEqual(AiClient.estimateTokens("abcde"), 2)
        // UTF-16 length, like JavaScript string.length
        XCTAssertEqual(AiClient.estimateTokens("🙂"), 1)
    }

    func testMaxTokensAutoBehavior() {
        // min(2000, max(220, est + 180))
        XCTAssertEqual(AiClient.maxTokens("", 0), 220)
        XCTAssertEqual(AiClient.maxTokens(String(repeating: "a", count: 1600), 0), 580)
        XCTAssertEqual(AiClient.maxTokens(String(repeating: "a", count: 40_000), 0), 2000)
    }

    func testMaxTokensExplicitOverrides() {
        XCTAssertEqual(AiClient.maxTokens("", 1000), 1000)
        XCTAssertEqual(AiClient.maxTokens(String(repeating: "a", count: 10_000), 300), 300)
        // Zero is not a valid explicit limit and must never be sent.
        XCTAssertEqual(AiClient.maxTokens("", 0), 220)
    }

    func testTokenLimitSanitizes() {
        XCTAssertEqual(AiClient.tokenLimit(0), 0)
        XCTAssertEqual(AiClient.tokenLimit(-5), 0)
        XCTAssertEqual(AiClient.tokenLimit(1234), 1234)
    }

    // MARK: Prompt envelope

    func testPayloadEnvelope() {
        let payload = AiClient.payload("hello")
        XCTAssertTrue(payload.hasPrefix("Transform only the text inside the tags."))
        XCTAssertTrue(payload.contains("<text>\nhello\n</text>"))
    }

    func testMessagesIncludeSystemPromptAndUserContent() {
        let messages = AiClient.messages("System rules", "abc", .transform)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], "System rules")
        XCTAssertEqual(messages[1]["role"], "user")
        XCTAssertTrue(messages[1]["content"]?.contains("<text>\nabc\n</text>") ?? false)
    }

    func testPromptModeSendsRawSelectionWithoutSystemWhenEmpty() {
        let messages = AiClient.messages("   ", "translate me", .prompt)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"], "user")
        XCTAssertEqual(messages[0]["content"], "translate me")
    }

    // MARK: Output cleaning (transform mode only)

    func testCleanOutputStripsTagEnvelope() {
        XCTAssertEqual(
            AiClient.cleanOutput("<text>\nFixed text\n</text>", inputMode: .transform),
            "Fixed text")
        XCTAssertEqual(
            AiClient.cleanOutput("<TEXT>Fixed</TEXT>", inputMode: .transform),
            "Fixed")
    }

    func testCleanOutputStripsCodeFence() {
        XCTAssertEqual(
            AiClient.cleanOutput("```text\nFixed\n```", inputMode: .transform), "Fixed")
        XCTAssertEqual(
            AiClient.cleanOutput("```\nFixed\n```", inputMode: .transform), "Fixed")
    }

    func testCleanOutputLeavesOtherContent() {
        XCTAssertEqual(AiClient.cleanOutput("plain", inputMode: .transform), "plain")
        // Only fully wrapped content is unwrapped.
        XCTAssertEqual(
            AiClient.cleanOutput("```text\nabc\n```\nmore", inputMode: .transform),
            "```text\nabc\n```\nmore")
    }

    func testCleanOutputKeptInPromptMode() {
        XCTAssertEqual(
            AiClient.cleanOutput("<text>raw</text>", inputMode: .prompt),
            "<text>raw</text>")
    }

    // MARK: Variable expansion (single pass)

    private var config = AiConfig(
        provider: "groq", ollamaURL: "", cloudflareAccountID: "",
        promptCorrect: "", promptRewrite: "", promptRun: "",
        variableLanguage: "German", variableTone: "friendly", variableStyle: "concise")

    func testExpandPromptReplacesAllVariables() {
        let result = AiClient.expandPrompt(
            "Rewrite ${selection} in ${language} with a ${tone} tone, ${style}.",
            text: "hi", config: config)
        XCTAssertEqual(
            result, "Rewrite hi in German with a friendly tone, concise.")
    }

    func testExpandPromptIsSinglePass() {
        // A selection containing variable syntax must not be re-expanded.
        let result = AiClient.expandPrompt(
            "${selection} ${language}", text: "text with ${language} inside",
            config: config)
        XCTAssertEqual(result, "text with ${language} inside German")
    }

    func testExpandPromptLeavesUnknownVariables() {
        XCTAssertEqual(
            AiClient.expandPrompt("keep ${unknown}", text: "x", config: config),
            "keep ${unknown}")
        XCTAssertEqual(
            AiClient.expandPrompt("no close ${selection", text: "x", config: config),
            "no close ${selection")
    }

    // MARK: OpenAI-compatible output extraction

    private let client = AiClient.shared

    func testOutputOrErrorExtractsContentAndCleans() throws {
        let result = AiClient.RequestResult(
            status: 200,
            data: [
                "choices": [[
                    "finish_reason": "stop",
                    "message": ["content": "<text>\nClean\n</text>"],
                ]]
            ])
        let output = try client.outputOrError(
            result, providerName: "Groq", model: "m", inputMode: .transform)
        XCTAssertEqual(output, "Clean")
    }

    func testOutputOrErrorRejectsTruncatedResponse() {
        let result = AiClient.RequestResult(
            status: 200,
            data: [
                "choices": [
                    ["finish_reason": "length", "message": ["content": "partial"]]
                ]
            ])
        XCTAssertThrowsError(try client.outputOrError(
            result, providerName: "Groq", model: "m", inputMode: .transform)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("output limit"),
                "unexpected: \(error.localizedDescription)")
        }
    }

    func testOutputOrErrorFallsBackToProviderErrorWhenEmpty() {
        let result = AiClient.RequestResult(status: 200, data: ["choices": []])
        XCTAssertThrowsError(try client.outputOrError(
            result, providerName: "Groq", model: "m", inputMode: .transform)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("unexpected response"))
        }
    }
}
