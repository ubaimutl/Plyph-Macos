import XCTest
@testable import PromptPaste

final class ModelCatalogTests: XCTestCase {
    func testUniqueSortedDeduplicatesAndSortsByName() {
        let models = [
            ModelOption(id: "b", name: "Beta"),
            ModelOption(id: "a", name: "alpha"),
            ModelOption(id: "b", name: "Beta duplicate"),
            ModelOption(id: "", name: "invalid"),
            ModelOption(id: "c", name: "Gamma"),
        ]
        let result = ModelCatalog.uniqueSorted(models)
        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    func testCacheRoundTrip() {
        let suiteName = "ModelCatalogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let models = [
            ModelOption(id: "m1", name: "One"),
            ModelOption(id: "m2", name: "Two"),
        ]
        ModelCatalog.cacheModels(models, provider: "groq", defaults: defaults)
        XCTAssertEqual(
            ModelCatalog.cachedModels(provider: "groq", defaults: defaults), models)
        // Other providers are untouched.
        XCTAssertTrue(ModelCatalog.cachedModels(provider: "openai", defaults: defaults).isEmpty)
    }

    func testPickerOptionsInsertsCurrentModelWhenMissing() {
        let suiteName = "ModelCatalogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ModelCatalog.cacheModels(
            [ModelOption(id: "a", name: "A")], provider: "groq", defaults: defaults)
        let options = ModelCatalog.pickerOptions(
            provider: "groq", current: "custom-model", defaults: defaults)
        XCTAssertEqual(options.first?.id, "custom-model")
        XCTAssertEqual(options.count, 2)
    }

    func testProviderRegistryParity() {
        // The 8 GNOME providers must exist with their default models.
        let expected: [(String, String, String)] = [
            ("ollama", "Ollama (local)", "qwen3:4b"),
            ("groq", "Groq", "openai/gpt-oss-20b"),
            ("cloudflare", "Cloudflare Workers AI", "@cf/qwen/qwen3-30b-a3b-fp8"),
            ("gemini", "Gemini", "gemini-3.5-flash-lite"),
            ("openrouter", "OpenRouter", "openrouter/free"),
            ("cerebras", "Cerebras", "gpt-oss-120b"),
            ("openai", "OpenAI", "gpt-4.1-mini"),
            ("vercel", "Vercel AI Gateway", "openai/gpt-5.4-mini"),
        ]
        for (id, name, model) in expected {
            let info = Providers.info(for: id)
            XCTAssertEqual(info?.name, name, id)
            XCTAssertEqual(info?.defaultModel, model, id)
        }
        XCTAssertTrue(Providers.info(for: "ollama")?.requiresKey == false)
        XCTAssertEqual(
            Providers.info(for: .cloudflare).credentialLabel, "API token")
    }
}
