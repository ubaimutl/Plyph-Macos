import XCTest
@testable import Plyph

final class ActionCatalogStoreTests: XCTestCase {
    private struct DataSource: ActionCatalogSource {
        let data: Data
        func load() throws -> Data { data }
    }

    private func makeStore(_ json: String) -> ActionCatalogStore {
        ActionCatalogStore(source: DataSource(data: Data(json.utf8)))
    }

    private func makeSettings() -> SettingsStore {
        let defaults = UserDefaults(
            suiteName: "ActionCatalogStoreTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.customActions = []
        return settings
    }

    private let sampleJSON = """
    [
      {
        "id": "explain-code", "name": "Explain Code",
        "description": "Understand selected code clearly.",
        "category": "Development", "icon": "chevron.left.forwardslash.chevron.right",
        "prompt": "Explain this code.", "inputMode": "transform",
        "outputBehavior": "preview",
        "visibilityConditions": [{"type": "looksLikeCode"}],
        "tags": ["source", "walkthrough"], "featured": true
      },
      {
        "id": "shorten", "name": "Shorten",
        "description": "Make writing more concise.",
        "category": "Writing", "icon": "text.alignleft",
        "prompt": "Shorten this text.", "inputMode": "transform",
        "outputBehavior": "preview", "visibilityConditions": [],
        "tags": ["brief", "condense"], "featured": false
      }
    ]
    """

    func testBundledCatalogLoadsAndHasUniqueIDs() {
        let actions = ActionCatalogStore.shared.actions
        XCTAssertEqual(actions.count, 48)
        XCTAssertEqual(Set(actions.map(\.id)).count, actions.count)
        XCTAssertEqual(Set(actions.map(\.category)), Set(CatalogCategory.allCases))
        XCTAssertTrue(ActionCatalogStore.shared.validationIssues.isEmpty)
    }

    func testInvalidEntriesAreSkippedWithoutDiscardingValidEntries() {
        let json = """
        [
          {"id":"bad-category","name":"Bad","description":"Bad", "category":"Random",
           "icon":"xmark","prompt":"Do it","inputMode":"transform",
           "outputBehavior":"preview","visibilityConditions":[],"tags":[],"featured":false},
          {"id":"empty","name":"","description":"Bad", "category":"Writing",
           "icon":"xmark","prompt":"Do it","inputMode":"transform",
           "outputBehavior":"preview","visibilityConditions":[],"tags":[],"featured":false},
          {"id":"valid","name":"Valid","description":"Works", "category":"Reading",
           "icon":"doc","prompt":"Summarize.","inputMode":"transform",
           "outputBehavior":"preview","visibilityConditions":[],"tags":[],"featured":false},
          {"id":"valid","name":"Duplicate","description":"Skipped", "category":"Reading",
           "icon":"doc","prompt":"Again.","inputMode":"transform",
           "outputBehavior":"preview","visibilityConditions":[],"tags":[],"featured":false}
        ]
        """
        let store = makeStore(json)

        XCTAssertEqual(store.actions.map(\.id), ["valid"])
        XCTAssertEqual(store.validationIssues.count, 3)
    }

    func testCategoryFilteringAndSearchAcrossFields() {
        let store = makeStore(sampleJSON)

        XCTAssertEqual(store.filtered(category: .writing, search: "").map(\.id), ["shorten"])
        XCTAssertEqual(store.filtered(category: nil, search: "Explain").map(\.id), ["explain-code"])
        XCTAssertEqual(store.filtered(category: nil, search: "concise").map(\.id), ["shorten"])
        XCTAssertEqual(store.filtered(category: nil, search: "walkthrough").map(\.id), ["explain-code"])
        XCTAssertTrue(store.filtered(category: .writing, search: "code").isEmpty)
    }

    func testConversionCreatesIndependentEditableCustomAction() {
        let template = makeStore(sampleJSON).actions[0]
        var installed = template.makeCustomAction(id: "installed-id")

        XCTAssertEqual(installed.id, "installed-id")
        XCTAssertEqual(installed.sourceCatalogID, template.id)
        XCTAssertEqual(installed.outputBehavior, template.outputBehavior)
        XCTAssertEqual(installed.visibilityConditions, template.visibilityConditions)

        installed.name = "My Edited Action"
        installed.prompt = "A different prompt"
        XCTAssertEqual(template.name, "Explain Code")
        XCTAssertEqual(template.prompt, "Explain this code.")
    }

    func testInstallDetectionDuplicatePreventionAndDeletion() {
        let store = makeStore(sampleJSON)
        let settings = makeSettings()
        let template = store.actions[0]

        guard case .installed(let installed) = store.install(
            actionID: template.id,
            in: settings) else {
            return XCTFail("Expected installation")
        }
        XCTAssertTrue(store.isInstalled(template, in: settings.customActions))
        XCTAssertEqual(settings.customActions.count, 1)
        XCTAssertEqual(store.install(actionID: template.id, in: settings), .alreadyInstalled)
        XCTAssertEqual(settings.customActions.count, 1)

        settings.customActions.removeAll { $0.id == installed.id }
        XCTAssertFalse(store.isInstalled(template, in: settings.customActions))
        guard case .installed = store.install(actionID: template.id, in: settings) else {
            return XCTFail("Expected reinstallation after deletion")
        }
    }
}
