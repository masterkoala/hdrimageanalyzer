import SwiftUI
import UniformTypeIdentifiers
import Common
import MetalEngine
import Capture
import Scopes

// MARK: - Quadrant drag payload (UI-003)

/// Payload for drag-to-swap between quadrants. Conforms to Transferable for SwiftUI draggable/onDrop.
public struct QuadrantDragItem: Codable, Transferable {
    public let quadrantIndex: Int

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

// MARK: - Quadrant content type (UI-002)

/// Content that can be shown in each quadrant: video preview or any scope.
public enum QuadrantContent: String, CaseIterable, Codable {
    case video = "Video"
    case waveform = "Waveform"
    case vectorscope = "Vectorscope"
    case histogram = "Histogram"
    case parade = "RGB Parade"
    case ciexy = "CIE xy"
    case falseColor = "False Color"
    case audio = "Audio Meters"
    case lutPreview = "LUT Preview"
    case colorSpace3D = "3D Color"

    public var displayName: String { rawValue }

    /// SF Symbol icon for layout toolbar / panel headers.
    public var iconName: String {
        switch self {
        case .video: return "video"
        case .waveform: return "waveform"
        case .vectorscope: return "scope"
        case .histogram: return "chart.bar"
        case .parade: return "chart.bar.xaxis"
        case .ciexy: return "circle.hexagongrid"
        case .falseColor: return "paintpalette"
        case .audio: return "speaker.wave.3"
        case .lutPreview: return "cube.transparent"
        case .colorSpace3D: return "cube"
        }
    }
}

// MARK: - Scope panel quadrant view (picker + content)

/// One quadrant of the scope panel container: menu to select content (video or scope), then the selected view.
public struct ScopePanelQuadrantView: View {
    let quadrantIndex: Int
    @Binding var content: QuadrantContent
    let captureState: CapturePreviewState
    let pipeline: MasterPipeline?
    let waveformScope: WaveformScope
    let histogramScope: HistogramScope
    @Binding var waveformMode: WaveformMode
    let waveformLuminanceScale: GraticuleLuminanceScale
    @Binding var waveformLogScale: Bool
    let waveformSingleLineMode: Bool
    var onEnterFullScreen: (() -> Void)?

    public init(
        quadrantIndex: Int,
        content: Binding<QuadrantContent>,
        captureState: CapturePreviewState,
        pipeline: MasterPipeline?,
        waveformScope: WaveformScope,
        histogramScope: HistogramScope,
        waveformMode: Binding<WaveformMode>,
        waveformLuminanceScale: GraticuleLuminanceScale,
        waveformLogScale: Binding<Bool>,
        waveformSingleLineMode: Bool = false,
        onEnterFullScreen: (() -> Void)? = nil
    ) {
        self.quadrantIndex = quadrantIndex
        self._content = content
        self.captureState = captureState
        self.pipeline = pipeline
        self.waveformScope = waveformScope
        self.histogramScope = histogramScope
        self._waveformMode = waveformMode
        self.waveformLuminanceScale = waveformLuminanceScale
        self._waveformLogScale = waveformLogScale
        self.waveformSingleLineMode = waveformSingleLineMode
        self.onEnterFullScreen = onEnterFullScreen
    }

    public var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $content) {
                ForEach(QuadrantContent.allCases, id: \.rawValue) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu {
                    scopePanelContextMenu(content: $content, onEnterFullScreen: onEnterFullScreen)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var contentView: some View {
        ScopePanelContentOnlyView(
            content: $content,
            quadrantIndex: quadrantIndex,
            captureState: captureState,
            pipeline: pipeline,
            waveformScope: waveformScope,
            histogramScope: histogramScope,
            waveformMode: $waveformMode,
            waveformLuminanceScale: waveformLuminanceScale,
            waveformLogScale: $waveformLogScale,
            waveformSingleLineMode: waveformSingleLineMode
        )
    }
}

// MARK: - Scope content only (for full-screen, UI-004)

/// Renders only the scope/video content (no picker). Used by full-screen single scope panel.
public struct ScopePanelContentOnlyView: View {
    @Binding var content: QuadrantContent
    let quadrantIndex: Int
    let captureState: CapturePreviewState
    let pipeline: MasterPipeline?
    let waveformScope: WaveformScope
    let histogramScope: HistogramScope
    @Binding var waveformMode: WaveformMode
    let waveformLuminanceScale: GraticuleLuminanceScale
    @Binding var waveformLogScale: Bool
    let waveformSingleLineMode: Bool
    @EnvironmentObject var sharedState: SharedAppState

    public var body: some View {
        contentView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu {
                scopePanelContextMenu(content: $content, onEnterFullScreen: nil)
            }
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case .video:
            CapturePreviewView(state: captureState)
        case .waveform:
            VStack(spacing: 0) {
                WaveformScopeView(
                    scope: waveformScope,
                    pipeline: pipeline,
                    waveformMode: $waveformMode,
                    graticuleLuminanceScale: waveformLuminanceScale,
                    waveformLogScale: waveformLogScale,
                    waveformSingleLineMode: waveformSingleLineMode
                )
                scopeSettingsRow(label: "Waveform", gain: $sharedState.waveformGain, gamma: $sharedState.waveformGamma)
            }
        case .vectorscope:
            VStack(spacing: 0) {
                VectorscopeScopeView(pipeline: pipeline)
                scopeSettingsRow(label: "Vectorscope", gain: $sharedState.vectorscopeGain, gamma: $sharedState.vectorscopeGamma)
            }
        case .histogram:
            HistogramScopeView(scope: histogramScope, pipeline: pipeline)
        case .parade:
            VStack(spacing: 0) {
                ParadeScopeView(pipeline: pipeline)
                scopeSettingsRow(label: "Parade", gain: $sharedState.paradeGain, gamma: $sharedState.paradeGamma)
            }
        case .ciexy:
            VStack(spacing: 0) {
                CIEChromaticityScopeView(pipeline: pipeline, showSpectralLocus: true)
                scopeSettingsRow(label: "CIE xy", gain: $sharedState.ciexyGain, gamma: $sharedState.ciexyGamma)
            }
        case .falseColor:
            FalseColorScopeView(config: sharedState.falseColorConfig)
        case .audio:
            AudioMeterView(
                peakLevels: sharedState.audioMeterPeakLevels,
                rmsLevels: sharedState.audioMeterRmsLevels,
                showRMS: sharedState.audioMeterShowRMS,
                channelLabels: sharedState.audioChannelLabels
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .lutPreview:
            LUTPreviewPanelView()
                .environmentObject(sharedState)
        case .colorSpace3D:
            ColorSpace3DView(pipeline: pipeline)
        }
    }
}

/// Compact gain/gamma settings row for scope quadrant panels.
@ViewBuilder
private func scopeSettingsRow(label: String, gain: Binding<Float>, gamma: Binding<Float>) -> some View {
    HStack(spacing: 8) {
        Text("Gain")
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.5))
        Slider(value: gain, in: 0.5...2.0, step: 0.05)
            .frame(maxWidth: 80)
        Text(String(format: "%.2f", gain.wrappedValue))
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(.white.opacity(0.6))
            .frame(width: 32, alignment: .trailing)
        Divider().frame(height: 12)
        Text("Gamma")
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.5))
        Slider(value: gamma, in: 0.3...1.0, step: 0.05)
            .frame(maxWidth: 80)
        Text(String(format: "%.2f", gamma.wrappedValue))
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(.white.opacity(0.6))
            .frame(width: 32, alignment: .trailing)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.black.opacity(0.3))
}

// MARK: - Right-click context menu (UI-015)

@ViewBuilder
private func scopePanelContextMenu(content: Binding<QuadrantContent>, onEnterFullScreen: (() -> Void)?) -> some View {
    Section("Switch to") {
        ForEach(QuadrantContent.allCases, id: \.rawValue) { item in
            Button(item.displayName) {
                content.wrappedValue = item
            }
        }
    }
    if let onEnter = onEnterFullScreen {
        Divider()
        Button("Enter Full Screen") {
            onEnter()
        }
    }
}
