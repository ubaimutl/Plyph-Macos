import Foundation

protocol ActionCatalogSource {
    func load() throws -> Data
}

struct BundledActionCatalogSource: ActionCatalogSource {
    private final class BundleToken {}

    func load() throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: "ActionCatalog", withExtension: "json") else {
            throw CatalogLoadingError.resourceMissing
        }
        return try Data(contentsOf: url)
    }
}

enum CatalogLoadingError: Error, Equatable {
    case resourceMissing
    case invalidRoot
}

enum CatalogInstallResult: Equatable {
    case installed(CustomAction)
    case alreadyInstalled
    case actionNotFound
}

/// Loads the offline catalog once, validates entries independently, and exposes
/// installation helpers without coupling the UI to the bundled JSON source.
final class ActionCatalogStore {
    static let shared = ActionCatalogStore(source: BundledActionCatalogSource())

    let actions: [CatalogAction]
    let validationIssues: [String]

    init(source: ActionCatalogSource) {
        do {
            let loaded = try Self.decodeLossy(try source.load())
            actions = loaded.actions
            validationIssues = loaded.issues
        } catch {
            actions = []
            validationIssues = ["Could not load ActionCatalog.json: \(error)"]
        }

        #if DEBUG
        validationIssues.forEach { NSLog("Plyph Action Library: %@", $0) }
        #endif
    }

    var featuredActions: [CatalogAction] {
        actions.filter(\.featured)
    }

    func filtered(category: CatalogCategory?, search: String) -> [CatalogAction] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return actions.filter { action in
            guard category == nil || action.category == category else { return false }
            guard !query.isEmpty else { return true }
            return action.name.localizedCaseInsensitiveContains(query)
                || action.description.localizedCaseInsensitiveContains(query)
                || action.tags.contains(where: {
                    $0.localizedCaseInsensitiveContains(query)
                })
        }
    }

    func isInstalled(_ action: CatalogAction, in installedActions: [CustomAction]) -> Bool {
        installedActions.contains { $0.sourceCatalogID == action.id }
    }

    @discardableResult
    func install(actionID: String, in settings: SettingsStore) -> CatalogInstallResult {
        guard let template = actions.first(where: { $0.id == actionID }) else {
            return .actionNotFound
        }
        guard !isInstalled(template, in: settings.customActions) else {
            return .alreadyInstalled
        }
        let action = template.makeCustomAction()
        settings.customActions.append(action)
        return .installed(action)
    }

    static func decodeLossy(_ data: Data) throws -> (actions: [CatalogAction], issues: [String]) {
        guard let rawEntries = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw CatalogLoadingError.invalidRoot
        }

        let decoder = JSONDecoder()
        var actions: [CatalogAction] = []
        var issues: [String] = []
        var seenIDs = Set<String>()

        for (index, rawEntry) in rawEntries.enumerated() {
            do {
                let entryData = try JSONSerialization.data(withJSONObject: rawEntry)
                let action = try decoder.decode(CatalogAction.self, from: entryData)
                guard action.isValid else {
                    issues.append("Entry \(index + 1) has an empty ID, name, or prompt and was skipped.")
                    continue
                }
                guard seenIDs.insert(action.id).inserted else {
                    issues.append("Duplicate catalog ID '\(action.id)' was skipped.")
                    continue
                }
                actions.append(action)
            } catch {
                issues.append("Entry \(index + 1) is invalid and was skipped: \(error)")
            }
        }
        return (actions, issues)
    }
}
