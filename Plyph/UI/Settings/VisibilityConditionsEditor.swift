import SwiftUI

struct VisibilityConditionsEditor: View {
    @Binding var conditions: [ActionVisibilityCondition]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Visibility")
                .font(.caption)
                .foregroundColor(.secondary)
            if conditions.isEmpty {
                Text("Always")
                    .foregroundColor(.secondary)
            }
            ForEach(Array(conditions.enumerated()), id: \.offset) { index, condition in
                HStack(spacing: 8) {
                    conditionEditor(condition, at: index)
                    Spacer()
                    Button {
                        conditions.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Menu {
                Button("Editable text only") { add(.editableTextOnly) }
                Button("Single word") { add(.singleWord) }
                Button("URL") { add(.url) }
                Button("Email address") { add(.emailAddress) }
                Button("Looks like code") { add(.looksLikeCode) }
                Divider()
                Button("Minimum length") { add(.minimumLength(20)) }
                Button("Maximum length") { add(.maximumLength(1000)) }
                Button("Only in app") { add(.appBundleIdentifier("com.example.app")) }
                Button("Exclude app") {
                    add(.excludedAppBundleIdentifier("com.example.app"))
                }
            } label: {
                Label("Add condition", systemImage: "plus")
            }
            Text("All listed conditions must match. Leave empty to always show the action.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func conditionEditor(_ condition: ActionVisibilityCondition, at index: Int)
        -> some View
    {
        switch condition {
        case .minimumLength(let value):
            Text("Minimum length")
            TextField("Characters", value: Binding(
                get: { value },
                set: { conditions[index] = .minimumLength(max(0, $0)) }),
                format: .number)
                .frame(width: 90)
        case .maximumLength(let value):
            Text("Maximum length")
            TextField("Characters", value: Binding(
                get: { value },
                set: { conditions[index] = .maximumLength(max(0, $0)) }),
                format: .number)
                .frame(width: 90)
        case .appBundleIdentifier(let value):
            Text("Only in app")
            TextField("Bundle identifier", text: Binding(
                get: { value },
                set: { conditions[index] = .appBundleIdentifier($0) }))
                .textFieldStyle(.roundedBorder)
        case .excludedAppBundleIdentifier(let value):
            Text("Exclude app")
            TextField("Bundle identifier", text: Binding(
                get: { value },
                set: { conditions[index] = .excludedAppBundleIdentifier($0) }))
                .textFieldStyle(.roundedBorder)
        default:
            Text(condition.title)
        }
    }

    private func add(_ condition: ActionVisibilityCondition) {
        guard !conditions.contains(condition) else { return }
        conditions.append(condition)
    }
}
