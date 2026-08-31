import XCTest
@testable import Plyph

final class ActionConfigurationTests: XCTestCase {
    func testQuickActionConfigurationNormalizesAndRoundTrips() throws {
        let configuration = QuickActionConfiguration(actions: [
            .ask, .correct, .ask, .rewrite, .prompt, .custom("extra"),
        ])
        XCTAssertEqual(configuration.actions, [.ask, .correct, .rewrite, .prompt])
        let json = ActionConfigurationStore.encode(configuration)
        XCTAssertEqual(
            ActionConfigurationStore.decode(QuickActionConfiguration.self, from: json),
            configuration)
    }

    func testProfileOverridesGlobalByBundleIdentifier() {
        let global = QuickActionConfiguration(actions: [.ask, .correct, .rewrite])
        let profile = AppActionProfile(
            bundleIdentifier: "COM.APPLE.SAFARI",
            actions: [.ask, .custom("summarize")])
        XCTAssertEqual(
            QuickActionResolver.references(
                global: global,
                profiles: [profile],
                bundleIdentifier: "com.apple.Safari",
                excludedBundleIdentifiers: []),
            [.ask, .custom("summarize")])
        XCTAssertEqual(
            QuickActionResolver.references(
                global: global,
                profiles: [profile],
                bundleIdentifier: "com.apple.mail",
                excludedBundleIdentifiers: []),
            global.actions)
    }

    func testExcludedAppTakesPriorityOverProfile() {
        let result = QuickActionResolver.references(
            global: .default,
            profiles: [AppActionProfile(
                bundleIdentifier: "com.apple.safari",
                actions: [.ask])],
            bundleIdentifier: "COM.APPLE.SAFARI",
            excludedBundleIdentifiers: ["com.apple.safari"])
        XCTAssertTrue(result.isEmpty)
    }

    func testSelectionDetectors() {
        XCTAssertTrue(context("hello").isSingleWord)
        XCTAssertFalse(context("hello world").isSingleWord)
        XCTAssertTrue(context("https://example.com/a?q=1").isURL)
        XCTAssertFalse(context("example.com").isURL)
        XCTAssertTrue(context("person+test@example.co.uk").isEmailAddress)
        XCTAssertFalse(context("person at example dot com").isEmailAddress)
        XCTAssertTrue(context("func greet() {\n    return \"Hi\"\n}").looksLikeCode)
        XCTAssertFalse(context("This is an ordinary sentence about a function.").looksLikeCode)
    }

    func testEveryVisibilityConditionMatchesDeterministically() {
        let value = SelectionContext(
            text: "https://example.com",
            bundleIdentifier: "com.apple.safari",
            isEditable: true)
        XCTAssertTrue(ActionVisibilityCondition.always.matches(value))
        XCTAssertTrue(ActionVisibilityCondition.editableTextOnly.matches(value))
        XCTAssertTrue(ActionVisibilityCondition.singleWord.matches(value))
        XCTAssertTrue(ActionVisibilityCondition.url.matches(value))
        XCTAssertFalse(ActionVisibilityCondition.emailAddress.matches(value))
        XCTAssertFalse(ActionVisibilityCondition.looksLikeCode.matches(value))
        XCTAssertTrue(ActionVisibilityCondition.minimumLength(5).matches(value))
        XCTAssertTrue(ActionVisibilityCondition.maximumLength(100).matches(value))
        XCTAssertTrue(
            ActionVisibilityCondition.appBundleIdentifier("COM.APPLE.SAFARI")
                .matches(value))
        XCTAssertFalse(
            ActionVisibilityCondition.excludedAppBundleIdentifier("com.apple.safari")
                .matches(value))
    }

    func testVisibilityConditionsRoundTrip() throws {
        let conditions: [ActionVisibilityCondition] = [
            .editableTextOnly,
            .minimumLength(10),
            .maximumLength(200),
            .appBundleIdentifier("com.apple.mail"),
            .excludedAppBundleIdentifier("com.apple.safari"),
        ]
        let json = ActionConfigurationStore.encode(conditions)
        XCTAssertEqual(
            ActionConfigurationStore.decode(
                [ActionVisibilityCondition].self,
                from: json),
            conditions)
    }

    func testQuickActionFilteringRemovesInapplicableAndUnavailableActions() {
        let suite = UserDefaults(suiteName: "QuickFilter-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: suite)
        let codeOnly = CustomAction(
            id: "code",
            name: "Explain",
            prompt: "Explain",
            visibilityConditions: [.looksLikeCode])
        settings.customActions = [codeOnly]
        settings.quickActionConfiguration = QuickActionConfiguration(actions: [
            .ask, .custom("code"), .custom("missing"), .correct,
        ])

        XCTAssertEqual(
            settings.resolvedQuickActions(for: context("ordinary words")).map(\.reference),
            [.ask, .correct])
        XCTAssertEqual(
            settings.resolvedQuickActions(for: context("let value = 1;")).map(\.reference),
            [.ask, .custom("code"), .correct])
    }

    private func context(_ text: String) -> SelectionContext {
        SelectionContext(text: text, bundleIdentifier: "com.example.app", isEditable: true)
    }
}
