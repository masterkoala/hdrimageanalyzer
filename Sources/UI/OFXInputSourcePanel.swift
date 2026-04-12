import SwiftUI
import Common
import OFX

// MARK: - OFX Input Source Selection Panel (UI-OFX-001)

/// Software-based input source panel that allows selection between DaVinci Resolve OFX and simulation modes.
/// Used when no physical DeckLink device is available or as an alternative capture method.
public struct OFXInputSourcePanel: View {
    @ObservedObject private var state: CapturePreviewState
    private let manager = OFXPluginManager.shared

    public init(state: CapturePreviewState) {
        self._state = ObservedObject(wrappedValue: state)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Software Input Source")
                .font(.headline)
                .foregroundColor(.primary)

            HStack(alignment: .top, spacing: 20) {
                sourceTypePicker
                resolutionSelector
                Button("Refresh") {
                    refreshOFXStatus()
                }
                .help("Re-check OFX plugin status")
            }

            Divider().padding(.vertical, 8)

            if let selectedSource = currentSelectedSource {
                StatusRow(source: selectedSource)
            }

            if !hasPluginInstalled {
                infoMessage
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .cornerRadius(8)
        .onAppear {
            refreshOFXStatus()
        }
    }

    private var sourceTypePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source Type")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $selectedSourceType) {
                Text("DaVinci Resolve OFX Input").tag(SourceType.resolveOFX)
                Text("Test Pattern Generator").tag(SourceType.testPattern)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 250)
        }
    }

    private var resolutionSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Resolution")
                .font(.caption)
                .foregroundColor(.secondary)
            Picker("", selection: $selectedResolution) {
                ForEach(OFXPluginManager.supportedResolutions, id: \.description) { res in
                    Text(res.description).tag(res)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 200)
        }
    }

    private var infoMessage: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.yellow)
            Text(
                """
                DaVinci Resolve OFX plugin not installed. Click "Install OFX Plugin" below to enable software input mode. \
                The plugin allows HDRImageAnalyzerPro to receive video signal from Resolve's OFX pipeline when no DeckLink hardware is present.
                """
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var currentSelectedSource: CaptureSource? {
        guard let type = selectedSourceType else { return nil }

        switch type {
        case .resolveOFX:
            if manager.isPluginInstalled("com.hdrimageanalyzerpro.resolve.input") {
                return OFXSoftwareInputSource(
                    id: "ofx_resolve_input",
                    name: "DaVinci Resolve OFX Input",
                    isPhysicalDevice: false,
                    ofxPluginId: "com.hdrimageanalyzerpro.resolve.input"
                )
            }
        case .testPattern:
            return OFXSoftwareInputSource(
                id: "test_pattern_generator",
                name: "Test Pattern Generator",
                isPhysicalDevice: false,
                enableSimulation: true
            )
        @unknown default:
            break
        }

        return nil
    }

    private var hasPluginInstalled: Bool {
        manager.isPluginInstalled("com.hdrimageanalyzerpro.resolve.input")
    }

    private var canInstallPlugin: Bool {
        !hasPluginInstalled && selectedSourceType == .resolveOFX
    }

    private enum SourceType {
        case resolveOFX
        case testPattern
    }

    @State private var selectedSourceType: SourceType? = nil
    @State private var selectedResolution: Resolution = .HD_1080p30
    @State private var isInstalling = false
    @State private var pluginStatusText = "Checking..."

    private func refreshOFXStatus() {
        let status = hasPluginInstalled ? "✓ Installed" : "✗ Not installed"
        pluginStatusText = status
    }

    private func installPluginButton() -> some View {
        Button(action: {
            isInstalling = true
            DispatchQueue.global(qos: .userInitiated).async {
                let result = manager.installOFXPlugin(targetDirectory: nil)
                DispatchQueue.main.async {
                    isInstalling = false
                    refreshOFXStatus()
                }
            }
        }) {
            Group {
                if isInstalling {
                    ProgressView("Installing...")
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.app")
                        Text("Install OFX Plugin")
                    }
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isInstalling)
    }

    private var currentSelectedSourceText: String {
        guard let source = currentSelectedSource else { return "No source selected" }
        return "\(source.sourceName) (\(source.currentSignalState == .present ? "Active" : "Inactive"))"
    }
}

// MARK: - Status Row Subview

private struct StatusRow: View {
    let source: CaptureSource

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(source.sourceName).font(.subheadline)
                Text("ID: \(source.sourceId)").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            StatusIndicator(state: source.currentSignalState)
        }
    }

    private var statusIcon: some View {
        Image(systemName: iconForSourceType())
            .foregroundColor(iconColor())
    }

    private func iconForSourceType() -> String {
        switch self.source.sourceId {
        case "ofx_resolve_input": return "link.badge.arrow.right"
        case "test_pattern_generator": return "circle.dashed"
        default: return "rectangle.fill"
        }
    }

    private func iconColor() -> Color {
        if let ofxInput = source as? OFXSoftwareInputSource, ofxInput.isPhysicalDevice {
            return .blue
        }
        return .orange
    }
}

// MARK: - Status Indicator

private struct StatusIndicator: View {
    let state: CaptureSignalState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForState())
                .frame(width: 12, height: 12)
            Text(textForState()).font(.caption)
        }
    }

    private func colorForState() -> Color {
        switch state {
        case .present: return .green
        case .lost: return .red
        case .unknown: return .gray
        @unknown default: return .gray
        }
    }

    private func textForState() -> String {
        switch state {
        case .present: return "Present"
        case .lost: return "Lost"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Extension for Resolution Array

extension OFXPluginManager {
    static let supportedResolutions: [Resolution] = [
        .HD_720p30,
        .HD_720p60,
        .HD_1080p24,
        .HD_1080p30,
        .HD_1080p60,
        .UHD_4K_p24,
        .UHD_4K_p30
    ]
}
