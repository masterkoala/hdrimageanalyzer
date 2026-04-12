import Foundation

/// SC-005: Waveform display mode — Luminance, RGB Overlay (R+G+B), YCbCr (Y+Cb+Cr), or Color (source pixel colors at luminance positions).
public enum WaveformMode: Int, CaseIterable {
    case luminance = 0
    case rgbOverlay = 1
    case yCbCr = 2
    case color = 3

    public var displayName: String {
        switch self {
        case .luminance: return "Luminance"
        case .rgbOverlay: return "RGB Overlay"
        case .yCbCr: return "YCbCr"
        case .color: return "Color"
        }
    }
}

/// Histogram display mode — Overlay (all channels on one graph), RGB Split (3 rows), RGBY Split (4 rows with luma).
public enum HistogramDisplayMode: Int, CaseIterable {
    case overlay = 0
    case rgbSplit = 1
    case rgbySplit = 2

    public var displayName: String {
        switch self {
        case .overlay: return "RGB Overlay"
        case .rgbSplit: return "RGB Split"
        case .rgbySplit: return "RGBY Split"
        }
    }

    /// Shader mode value passed to histogram_render_to_texture kernel.
    public var shaderMode: UInt32 { UInt32(rawValue) }
}
