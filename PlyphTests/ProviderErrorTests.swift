import XCTest
@testable import Plyph

final class ProviderErrorTests: XCTestCase {
    func testDetailExtraction() {
        XCTAssertEqual(
            ProviderErrorMapper.detail(from: ["error": ["message": "boom"]]), "boom")
        XCTAssertEqual(ProviderErrorMapper.detail(from: ["error": "plain"]), "plain")
        XCTAssertNil(ProviderErrorMapper.detail(from: [:]))
    }

    func testAuthErrors() {
        let error = ProviderErrorMapper.error(
            status: 401, data: [:], providerName: "Groq", model: "m")
        XCTAssertTrue(
            error.localizedDescription.contains("rejected the API key"),
            error.localizedDescription)

        let cloudflare = ProviderErrorMapper.error(
            status: 403, data: [:],
            providerName: Providers.info(for: .cloudflare).name, model: "m")
        XCTAssertTrue(
            cloudflare.localizedDescription.contains("Cloudflare rejected the API token or Account ID"))
    }

    func testModelNotFound() {
        let error = ProviderErrorMapper.error(
            status: 404, data: [:], providerName: "OpenAI", model: "gpt-nope")
        XCTAssertTrue(error.localizedDescription.contains("could not find model “gpt-nope”"))
    }

    func testRateLimitAndTimeout() {
        XCTAssertTrue(ProviderErrorMapper.error(
            status: 429, data: [:], providerName: "Groq", model: "m")
            .localizedDescription.contains("rate limit reached"))
        XCTAssertTrue(ProviderErrorMapper.error(
            status: 408, data: [:], providerName: "Groq", model: "m")
            .localizedDescription.contains("timed out"))
    }

    func testServerUnavailable() {
        let error = ProviderErrorMapper.error(
            status: 503, data: [:], providerName: "Groq", model: "m")
        XCTAssertTrue(error.localizedDescription.contains("temporarily unavailable (503)"))
    }

    func testClientErrorPrefersProviderDetail() {
        let error = ProviderErrorMapper.error(
            status: 422, data: ["error": ["message": "max_tokens is too large"]],
            providerName: "Groq", model: "m")
        XCTAssertEqual(error.localizedDescription, "max_tokens is too large")
    }

    func testClientErrorWithoutDetail() {
        let error = ProviderErrorMapper.error(
            status: 418, data: [:], providerName: "Groq", model: "m")
        XCTAssertEqual(error.localizedDescription, "Groq rejected the request (418).")
    }

    func testPromptErrorMessages() {
        XCTAssertEqual(
            PromptError.noSelection.localizedDescription, "Select text first.")
        XCTAssertEqual(
            PromptError.selectionCaptureFailed.localizedDescription,
            "Could not capture selected text. Select it and try again.")
        XCTAssertEqual(
            PromptError.releaseShortcutKeys.localizedDescription,
            "Release the shortcut keys and try again.")
        XCTAssertTrue(
            PromptError.inputLimitExceeded(estimated: 3000, limit: 2000)
                .localizedDescription
                .contains("about 3000 tokens"))
        XCTAssertTrue(
            PromptError.outputLimitReached.localizedDescription.contains("output limit"))
    }
}
