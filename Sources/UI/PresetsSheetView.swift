import SwiftUI
import AppKit
import Logging
import Common

// MARK: - UI-011 Layout preset save/recall

/// Sheet for saving, loading, and deleting layout presets (quadrant layout + app config).
public struct PresetsSheetView: View {
    @State private var presetNames: [String] = PresetManager.presetNames()
    @State private var selectedName: String?
    @State private var saveAsName: String = ""
    @State private var showSaveAsField: Bool = false
    @FocusState private var saveAsFieldFocused: Bool

    public var onLoad: (AppConfig) -> Void
    public var onSaveAs: (String) -> Void
    public var onDismiss: () -> Void

    public init(onLoad: @escaping (AppConfig) -> Void, onSaveAs: @escaping (String) -> Void, onDismiss: @escaping () -> Void) {
        self.onLoad = onLoad
        self.onSaveAs = onSaveAs
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 16) {
            Text("Layout Presets")
                .font(.headline)
            Text("Save or recall quadrant layout and app settings.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            List(selection: $selectedName) {
                ForEach(presetNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .frame(minHeight: 120)

            if showSaveAsField {
                HStack {
                    TextField("Preset name", text: $saveAsName)
                        .textFieldStyle(.roundedBorder)
                        .focused($saveAsFieldFocused)
                    Button("Save") {
                        saveCurrentAs(saveAsName)
                        saveAsName = ""
                        showSaveAsField = false
                    }
                    .disabled(saveAsName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") {
                        saveAsName = ""
                        showSaveAsField = false
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Load") {
                    loadSelected()
                }
                .disabled(selectedName == nil)
                .keyboardShortcut(.return, modifiers: [])

                Button("Save As...") {
                    showSaveAsField = true
                    saveAsFieldFocused = true
                }

                Button("Delete") {
                    deleteSelected()
                }
                .disabled(selectedName == nil)
                .keyboardShortcut(.delete, modifiers: [])

                Spacer()
                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 280)
        .onAppear {
            presetNames = PresetManager.presetNames()
        }
    }

    private func loadSelected() {
        guard let name = selectedName,
              let config = PresetManager.load(name: name) else { return }
        HDRLogger.info(category: "App", "Load preset: \(name)")
        onLoad(config)
        onDismiss()
    }

    private func saveCurrentAs(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        HDRLogger.info(category: "App", "Save preset: \(trimmed)")
        onSaveAs(trimmed)
        presetNames = PresetManager.presetNames()
        saveAsName = ""
        showSaveAsField = false
    }

    private func deleteSelected() {
        guard let name = selectedName else { return }
        PresetManager.delete(name: name)
        presetNames = PresetManager.presetNames()
        selectedName = nil
        HDRLogger.info(category: "App", "Delete preset: \(name)")
    }
}
