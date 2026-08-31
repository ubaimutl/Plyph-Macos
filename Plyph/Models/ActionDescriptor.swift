import AppKit

struct ActionDescriptor: Identifiable {
    let reference: ActionReference
    let name: String
    let iconName: String
    let mode: RunMode?
    let isAsk: Bool
    let conditions: [ActionVisibilityCondition]

    var id: String { reference.id }

    func isVisible(in context: SelectionContext?) -> Bool {
        guard let context else { return true }
        return conditions.allSatisfy { $0.matches(context) }
    }

    var icon: NSImage? {
        ActionSymbol.image(named: iconName)
    }
}

enum ActionCatalog {
    static func all(settings: SettingsStore) -> [ActionDescriptor] {
        var result = [
            ActionDescriptor(
                reference: .ask,
                name: "Ask",
                iconName: "questionmark.bubble",
                mode: nil,
                isAsk: true,
                conditions: []),
            ActionDescriptor(
                reference: .correct,
                name: "Correct",
                iconName: ActionSymbol.name(for: .correct),
                mode: .correct,
                isAsk: false,
                conditions: []),
            ActionDescriptor(
                reference: .rewrite,
                name: "Rewrite",
                iconName: ActionSymbol.name(for: .rewrite),
                mode: .rewrite,
                isAsk: false,
                conditions: []),
            ActionDescriptor(
                reference: .prompt,
                name: "Run Prompt",
                iconName: ActionSymbol.name(for: .prompt),
                mode: .prompt,
                isAsk: false,
                conditions: []),
        ]
        result += settings.enabledCustomActions.map { action in
            ActionDescriptor(
                reference: .custom(action.id),
                name: action.name,
                iconName: ActionSymbol.name(for: .custom(action)),
                mode: .custom(action),
                isAsk: false,
                conditions: action.visibilityConditions)
        }
        return result
    }

    static func descriptor(
        for reference: ActionReference,
        settings: SettingsStore
    ) -> ActionDescriptor? {
        all(settings: settings).first { $0.reference == reference }
    }

    static func quickActions(
        settings: SettingsStore,
        context: SelectionContext
    ) -> [ActionDescriptor] {
        let references = QuickActionResolver.references(
            global: settings.quickActionConfiguration,
            profiles: settings.appActionProfiles,
            bundleIdentifier: context.bundleIdentifier,
            excludedBundleIdentifiers: settings.excludedAppIdentifierList)
        var lookup: [ActionReference: ActionDescriptor] = [:]
        for descriptor in all(settings: settings) {
            lookup[descriptor.reference] = descriptor
        }
        return references.compactMap { lookup[$0] }
            .filter { $0.isVisible(in: context) }
            .prefix(QuickActionConfiguration.maximumCount)
            .map { $0 }
    }
}
