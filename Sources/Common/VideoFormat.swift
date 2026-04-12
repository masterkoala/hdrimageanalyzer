import Foundation

/// Shared video format and colorspace types (roadmap F-015).
public enum VideoFormat {
    case hd720p50
    case hd720p60
    case hd1080p50
    case hd1080p60
    case uhd4Kp24
    case uhd4Kp50
    case uhd4Kp60
    case custom(width: Int, height: Int, rate: Double)
}

public enum ColorSpace: String, Codable {
    case rec709
    case rec2020
    case p3
    case pq
    case hlg
}

/// CS-004: Gamut space for 3x3 matrix conversion (Rec.709, Rec.2020, DCI-P3, XYZ). Used for Analysis Space and Display Space menus (UI-008).
public enum GamutSpace: String, Codable, CaseIterable {
    case rec709
    case rec2020
    case dciP3
    case xyz

    /// Display name for menu items.
    public var displayName: String {
        switch self {
        case .rec709: return "Rec.709"
        case .rec2020: return "Rec.2020"
        case .dciP3: return "DCI-P3"
        case .xyz: return "XYZ"
        }
    }
}

/// SC-014/SC-015: False Color overlay mode. Brightness = luminance ramp; Gamut Warning = out-of-gamut pixels → magenta.
public enum FalseColorMode: String, Codable, CaseIterable {
    case brightness
    case gamutWarning

    public var displayName: String {
        switch self {
        case .brightness: return "Brightness"
        case .gamutWarning: return "Gamut Warning"
        }
    }
}

public enum PixelFormat: String, Codable {
    case v210
    case rgb10
    case rgb12
    case yuv8
}

/// Signal range for YCbCr→RGB conversion. Full = 0–1023 (10-bit). Legal = Y 64–940, CbCr 64–960 (SMPTE 274M).
public enum SignalRange: String, Codable, CaseIterable {
    case full
    case legal

    public var displayName: String {
        switch self {
        case .full: return "Full"
        case .legal: return "Legal"
        }
    }

    /// UInt32 flag for GPU shader (0 = full, 1 = legal).
    public var shaderValue: UInt32 {
        switch self {
        case .full: return 0
        case .legal: return 1
        }
    }
}
