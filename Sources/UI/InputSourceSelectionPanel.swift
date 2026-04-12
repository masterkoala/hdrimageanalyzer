import SwiftUI
import Capture

// MARK: - Input source selection panel (UI-007, DL-001)

/// Reusable panel for DeckLink input source selection: device and display format (DL-001).
/// Uses `DeckLinkDeviceManager.enumerateDevices()` and `DeckLinkGetDisplayModes` / `DeckLinkDevice.displayModes()`.
/// Binds to `CapturePreviewState` so selection drives capture; refreshes on device hot-plug (DL-012).
public struct InputSourceSelectionPanel: View {
    @ObservedObject private var state: CapturePreviewState

    public init(state: CapturePreviewState) {
        self._state = ObservedObject(wrappedValue: state)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input source")
                .font(.headline)
                .foregroundColor(.primary)

            HStack(alignment: .top, spacing: 20) {
                devicePicker
                inputConnectionPicker
                formatPicker
                Button("Refresh") {
                    state.refreshDevices(mergeFromIterator: true)
                }
                .help("Re-scan DeckLink devices (merge from driver, no duplicates)")
            }

            Toggle("Apply detected video mode", isOn: $state.applyDetectedVideoMode)
                .toggleStyle(.checkbox)
                .disabled(!state.supportsInputFormatDetection || state.isLive)
                .help("When on, capture follows signal format changes (CapturePreview sample). Mode list is disabled during capture.")
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
        .onAppear {
            state.startDeviceNotifications()
            state.refreshDevices(mergeFromIterator: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: DeckLinkDeviceManager.deckLinkDeviceListDidChangeNotification)) { _ in
            state.refreshDevices()
        }
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $state.selectedDeviceIndex) {
                ForEach(Array(state.devices.enumerated()), id: \.offset) { index, device in
                    Text(device.displayName).tag(index)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 200)
            .onChange(of: state.selectedDeviceIndex) { _, _ in
                state.refreshInputConnections()
                state.refreshModes()
            }
        }
    }

    private var inputConnectionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { state.selectedInputConnection },
                set: { state.setInputConnectionAndRefreshModes($0) }
            )) {
                ForEach(state.supportedInputConnections, id: \.rawValue) { conn in
                    Text(conn.displayName).tag(conn.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 120)
            .disabled(state.isLive || state.supportedInputConnections.isEmpty)
        }
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Format")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $state.selectedModeIndex) {
                ForEach(Array(state.modes.enumerated()), id: \.offset) { index, mode in
                    Text(formatDisplayModeLabel(mode)).tag(index)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 260)
            .disabled(state.isLive && state.applyDetectedVideoMode)
            .onChange(of: state.selectedModeIndex) { _, _ in
                // When user manually changes format during live capture (auto-detect OFF),
                // restart capture with the newly selected mode so the change takes effect.
                if state.isLive && !state.applyDetectedVideoMode {
                    state.stopCapture()
                    state.startCapture()
                }
            }
        }
    }

    private func formatDisplayModeLabel(_ mode: DeckLinkDisplayMode) -> String {
        "\(mode.name) (\(mode.width)×\(mode.height) \(mode.frameRate)fps)"
    }
}
