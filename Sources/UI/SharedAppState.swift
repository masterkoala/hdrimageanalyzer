import SwiftUI
import Combine
import Capture
import Scopes
import Common
import MetalEngine

/// Shared app state for main window and scopes-on-second-display window (UI-013). Holds capture pipeline and layout so both windows stay in sync.
public final class SharedAppState: ObservableObject {
    public let waveformScope = WaveformScope()
    public let histogramScope = HistogramScope()

    public lazy var captureState: CapturePreviewState = {
        let cs = CapturePreviewState(scope: waveformScope)
        cs.histogramScope = histogramScope
        return cs
    }()

    @Published public var quadrant1Content: QuadrantContent = .video
    @Published public var quadrant2Content: QuadrantContent = .waveform
    @Published public var quadrant3Content: QuadrantContent = .histogram
    @Published public var quadrant4Content: QuadrantContent = .vectorscope
    /// UI-016: When true, quadrant grid shows 4x video preview (Ch 1-4). When false, standard picker-per-quadrant layout.
    @Published public var isFourChannelMode: Bool = false
    @Published public var waveformMode: WaveformMode = .luminance
    @Published public var waveformLuminanceScale: GraticuleLuminanceScale = .sdrIRE
    @Published public var waveformLogScale: Bool = false
    /// SC-023: When true, waveform shows only one scan line (center row).
    @Published public var waveformSingleLineMode: Bool = false
    /// Histogram display mode: overlay, RGB split, RGBY split.
    @Published public var histogramDisplayMode: HistogramDisplayMode = .overlay
    /// SC-020: Per-scope intensity (brightness/gain). scopeGamma < 1 = more bloom; scopeGain scales output.
    @Published public var waveformGamma: Float = 0.45
    @Published public var waveformGain: Float = 1.0
    @Published public var vectorscopeGamma: Float = 0.45
    @Published public var vectorscopeGain: Float = 1.0
    @Published public var paradeGamma: Float = 0.45
    @Published public var paradeGain: Float = 1.0
    @Published public var ciexyGamma: Float = 0.45
    @Published public var ciexyGain: Float = 1.0
    /// Legacy global accessors (kept for backward compatibility)
    public var scopeGamma: Float {
        get { waveformGamma }
        set { waveformGamma = newValue; vectorscopeGamma = newValue; paradeGamma = newValue; ciexyGamma = newValue }
    }
    public var scopeGain: Float {
        get { waveformGain }
        set { waveformGain = newValue; vectorscopeGain = newValue; paradeGain = newValue; ciexyGain = newValue }
    }

    // MARK: - False Color

    /// False Color scope configuration (preset, ranges, opacity).
    @Published public var falseColorConfig = FalseColorConfig()

    // MARK: - Audio Meters (for quadrant audio scope)

    /// Audio peak levels for audio meter scope in quadrant.
    @Published public var audioMeterPeakLevels: [Float] = Array(repeating: -60, count: 2)
    /// Audio RMS levels for audio meter scope in quadrant.
    @Published public var audioMeterRmsLevels: [Float] = Array(repeating: -60, count: 2)
    /// Whether to show RMS overlay on audio meters.
    @Published public var audioMeterShowRMS: Bool = true
    /// Audio channel labels for audio meters.
    public var audioChannelLabels: [String] {
        let count = max(2, audioMeterPeakLevels.count)
        return (0..<count).map { "Ch \($0 + 1)" }
    }

    // MARK: - Flexible Layout

    /// Flexible layout manager for variable grid configurations.
    @Published public var layoutManager = FlexibleLayoutManager()

    // MARK: - Scope Visibility

    /// PERF-001: Derived set of visible scope types from quadrant content. Used to tell MasterPipeline which scopes to compute.
    public var visibleScopeTypes: Set<ScopeType> {
        var result = Set<ScopeType>()
        let allContents: [QuadrantContent]
        if layoutManager.panels.isEmpty {
            allContents = [quadrant1Content, quadrant2Content, quadrant3Content, quadrant4Content]
        } else {
            allContents = layoutManager.panels.map { $0.content }
        }
        for content in allContents {
            switch content {
            case .waveform: result.insert(.waveform)
            case .vectorscope: result.insert(.vectorscope)
            case .histogram: result.insert(.histogram)
            case .parade: result.insert(.parade)
            case .ciexy: result.insert(.ciexy)
            case .video, .falseColor, .audio, .lutPreview, .colorSpace3D: break
            }
        }
        return result
    }

    /// View zoom for main quadrant grid (View > Zoom In/Out/Actual Size). Range 0.5...2.0.
    @Published public var viewZoomScale: CGFloat = 1.0
    private static let viewZoomMin: CGFloat = 0.5
    private static let viewZoomMax: CGFloat = 2.0
    private static let viewZoomStep: CGFloat = 0.25

    public init() {
        let prefGamma = UserDefaults.standard.double(forKey: "HDRApp.Prefs.Scopes.ScopeGamma")
        let prefGain = UserDefaults.standard.double(forKey: "HDRApp.Prefs.Scopes.ScopeGain")
        if prefGamma > 0 {
            let g = Float(prefGamma)
            waveformGamma = g; vectorscopeGamma = g; paradeGamma = g; ciexyGamma = g
        }
        if prefGain > 0 {
            let g = Float(prefGain)
            waveformGain = g; vectorscopeGain = g; paradeGain = g; ciexyGain = g
        }
        // restoreFromDefaults() is called in FlexibleLayoutManager.init() already
    }

    public func viewZoomIn() {
        viewZoomScale = min(Self.viewZoomMax, viewZoomScale + Self.viewZoomStep)
    }

    public func viewZoomOut() {
        viewZoomScale = max(Self.viewZoomMin, viewZoomScale - Self.viewZoomStep)
    }

    public func viewActualSize() {
        viewZoomScale = 1.0
    }
}
