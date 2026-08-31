import XCTest
@testable import Plyph

final class SettingsStoreTests: XCTestCase {
    private func makeStore() -> (SettingsStore, UserDefaults) {
        let suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: defaults)
        return (store, defaults)
    }

    func testDefaultsMirrorGSettingsSchema() {
        let (store, defaults) = makeStore()
        XCTAssertEqual(store.provider, "groq")
        XCTAssertEqual(store.ollamaURL, "http://127.0.0.1:11434")
        XCTAssertEqual(store.ollamaModel, "qwen3:4b")
        XCTAssertEqual(store.cloudflareModel, "@cf/qwen/qwen3-30b-a3b-fp8")
        XCTAssertEqual(store.groqModel, "openai/gpt-oss-20b")
        XCTAssertEqual(store.openAIModel, "gpt-4.1-mini")
        XCTAssertEqual(store.geminiModel, "gemini-3.5-flash-lite")
        XCTAssertEqual(store.openRouterModel, "openrouter/free")
        XCTAssertEqual(store.vercelModel, "openai/gpt-5.4-mini")
        XCTAssertEqual(store.cerebrasModel, "gpt-oss-120b")
        XCTAssertEqual(store.previewResults, true)
        XCTAssertEqual(store.clipboardFallback, false)
        XCTAssertEqual(store.explicitCopyApps, "firefox")
        XCTAssertEqual(store.excludedApps, "")
        XCTAssertEqual(store.quickActionConfiguration, .default)
        XCTAssertTrue(store.appActionProfiles.isEmpty)
        XCTAssertEqual(
            store.customActions.map(\.id),
            CustomAction.starterActions.map(\.id))
        XCTAssertEqual(store.pointerFeedback, true)
        XCTAssertEqual(store.actionPalettePosition, "disabled")
        XCTAssertEqual(store.variableLanguage, "English")
        XCTAssertEqual(store.variableTone, "professional")
        XCTAssertEqual(store.variableStyle, "clear and concise")
        // Same values registered into defaults.
        XCTAssertEqual(
            defaults.string(forKey: "prompt-correct"),
            SettingsStore.defaultPromptCorrect)
        XCTAssertFalse(store.correctShortcutJSON.isEmpty == false)
    }

    func testModelAccessorsPerProvider() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.model(for: "groq"), "openai/gpt-oss-20b")
        store.setModel("custom-groq", for: "groq")
        XCTAssertEqual(store.model(for: "groq"), "custom-groq")
        store.setModel("custom-cf", for: "cloudflare")
        XCTAssertEqual(store.model(for: "cloudflare"), "custom-cf")
        XCTAssertEqual(store.model(for: "unknown"), "")
    }

    func testCustomActionsPersistedAsJSON() {
        let (store, defaults) = makeStore()
        let action = CustomAction(name: "Summarize", prompt: "Summarize ${selection}")
        store.customActions = [action]
        let saved = defaults.string(forKey: "custom-actions") ?? ""
        XCTAssertTrue(saved.contains("Summarize"))
        // A new store over the same defaults reads it back.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.customActions, [action])
    }

    func testExplicitlyEmptyCustomActionsDoNotRestoreStarters() {
        let suiteName = "SettingsStoreTests-empty-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("[]", forKey: "custom-actions")

        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.customActions.isEmpty)
    }

    func testShortcutPersistence() {
        let (store, defaults) = makeStore()
        let combo = HotKeyCombo(
            keyCode: 11, modifiers: UInt(HotKeyCombo.commandFlag | HotKeyCombo.shiftFlag),
            keySymbol: "B")
        store.correctShortcut = combo
        XCTAssertEqual(
            HotKeyCombo.from(jsonString: defaults.string(forKey: "correct-shortcut") ?? ""),
            combo)
    }

    func testExplicitCopyAppListParsing() {
        let (store, _) = makeStore()
        store.explicitCopyApps = " Firefox , org.mozilla.firefox\n,  ,VsCode"
        XCTAssertEqual(
            store.explicitCopyAppList,
            ["firefox", "org.mozilla.firefox", "vscode"])
        store.explicitCopyApps = ""
        XCTAssertEqual(store.explicitCopyAppList, [])
    }

    func testExcludedAppsAreIndependentAndPersisted() {
        let (store, defaults) = makeStore()
        store.excludeApp(bundleIdentifier: " COM.APPLE.SAFARI ")
        store.excludeApp(bundleIdentifier: "com.google.Chrome")
        store.excludeApp(bundleIdentifier: "com.apple.safari")

        XCTAssertEqual(
            store.excludedAppIdentifierList,
            ["com.apple.safari", "com.google.chrome"])
        XCTAssertTrue(store.isAppExcluded(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(store.isAppExcluded(bundleIdentifier: "org.mozilla.firefox"))

        store.includeApp(bundleIdentifier: "COM.APPLE.SAFARI")
        XCTAssertEqual(store.excludedAppIdentifierList, ["com.google.chrome"])

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.excludedAppIdentifierList, ["com.google.chrome"])
    }

    func testEnabledCustomActionsFilter() {
        let (store, _) = makeStore()
        store.customActions = [
            CustomAction(name: "On", prompt: "a", enabled: true),
            CustomAction(name: "Off", prompt: "b", enabled: false),
        ]
        XCTAssertEqual(store.enabledCustomActions.map(\.name), ["On"])
    }

    func testQuickActionsAndProfilesPersist() {
        let (store, defaults) = makeStore()
        store.quickActionConfiguration = QuickActionConfiguration(actions: [.ask, .prompt])
        store.setProfile(AppActionProfile(
            bundleIdentifier: "com.apple.mail",
            actions: [.ask, .correct]))

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.quickActionConfiguration.actions, [.ask, .prompt])
        XCTAssertEqual(
            reloaded.appActionProfiles,
            [AppActionProfile(
                bundleIdentifier: "com.apple.mail",
                actions: [.ask, .correct])])
    }
}
