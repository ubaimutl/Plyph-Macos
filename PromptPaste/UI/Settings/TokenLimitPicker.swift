import SwiftUI

/// Token limit picker with the GNOME presets plus a custom entry:
/// Input: Auto/2K/4K/8K/16K/32K, Output: Auto/1K/2K/4K/8K/16K.
struct TokenLimitPicker: View {
    static let inputPresets = [0, 2000, 4000, 8000, 16000, 32000]
    static let outputPresets = [0, 1000, 2000, 4000, 8000, 16000]

    let title: String
    let subtitle: String
    let presets: [Int]
    @Binding var binding: Int

    @State private var customMode = false
    @State private var customText = ""

    private var selectedPresetIndex: Int? {
        presets.firstIndex(of: binding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                Picker(title, selection: Binding(
                    get: { customMode ? -1 : (selectedPresetIndex ?? -1) },
                    set: { newValue in
                        if newValue >= 0 {
                            customMode = false
                            binding = presets[newValue]
                        } else {
                            customMode = true
                        }
                    }
                )) {
                    ForEach(Array(presets.enumerated()), id: \.offset) { index, value in
                        Text(label(for: value)).tag(index)
                    }
                    Text("Custom…").tag(-1)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if customMode {
                HStack(spacing: 6) {
                    TextField("Custom \(title.lowercased())", text: $customText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitCustom)
                    Button("Apply") { commitCustom() }
                }
                if !customText.isEmpty && Int(customText) == nil {
                    Text("Enter a positive number of tokens.")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }

            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            customMode = selectedPresetIndex == nil && binding > 0
            customText = binding > 0 ? String(binding) : ""
        }
    }

    private func label(for value: Int) -> String {
        CustomAction.formatTokenLimit(value)
    }

    private func commitCustom() {
        guard let parsed = Int(customText.trimmingCharacters(in: .whitespaces)),
            parsed > 0
        else { return }
        binding = parsed
    }
}
