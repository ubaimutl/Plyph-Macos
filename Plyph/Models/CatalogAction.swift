import Foundation

enum CatalogCategory: String, Codable, CaseIterable, Identifiable {
    case writing = "Writing"
    case communication = "Communication"
    case reading = "Reading"
    case development = "Development"
    case translation = "Translation"
    case productivity = "Productivity"

    var id: String { rawValue }
}

/// An immutable template decoded from the offline catalog bundled with Plyph.
struct CatalogAction: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let category: CatalogCategory
    let icon: String
    let prompt: String
    let inputMode: InputMode
    let outputBehavior: ActionOutputBehavior
    let visibilityConditions: [ActionVisibilityCondition]
    let tags: [String]
    let featured: Bool

    var isValid: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func makeCustomAction(id: String = UUID().uuidString) -> CustomAction {
        CustomAction(
            id: id,
            name: name,
            prompt: prompt,
            inputMode: inputMode,
            outputBehavior: outputBehavior,
            visibilityConditions: visibilityConditions,
            sourceCatalogID: self.id)
    }
}
