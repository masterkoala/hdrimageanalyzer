import SwiftUI
import AppKit
import Metal
import MetalKit
import Logging
import Common
import MetalEngine

/// Inline theme colors for False Color scope (avoids dependency on HDRUI module's AJATheme).
private enum AJATheme {
    static let panelBackground = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let statusBarBackground = Color(red: 0.10, green: 0.10, blue: 0.12)
    static let divider = Color(red: 0.25, green: 0.25, blue: 0.28)
    static let primaryText = Color(red: 0.92, green: 0.92, blue: 0.94)
    static let secondaryText = Color(red: 0.62, green: 0.62, blue: 0.66)
    static let tertiaryText = Color(red: 0.45, green: 0.45, blue: 0.50)
}

// MARK: - SC-030: False Color scope — IRE-based false color overlay for exposure analysis
// Professional false color implementation inspired by Nobe Omniscope. Maps luminance IRE values
// to a configurable color palette for rapid exposure evaluation. Supports industry-standard
// presets (ARRI, RED, Sony, Canon, Panasonic, BMD, ACES, EBU, SMPTE) and custom user palettes.

// MARK: - False Color Preset Enum

/// Industry-standard false color preset identifiers. Each preset defines a set of IRE ranges
/// mapped to specific colors optimized for that manufacturer's workflow or broadcast standard.
public enum FalseColorPreset: String, CaseIterable, Identifiable {
    case defaultPreset = "Default"
    case arri = "ARRI"
    case red = "RED"
    case sony = "Sony"
    case canon = "Canon"
    case panasonic = "Panasonic"
    case bmd = "Blackmagic"
    case aces = "ACES"
    case ebu = "EBU"
    case smpte = "SMPTE"
    case custom1 = "Custom 1"
    case custom2 = "Custom 2"
    case custom3 = "Custom 3"

    public var id: String { rawValue }

    public var displayName: String { rawValue }
}

// MARK: - False Color Range

/// A single IRE range mapped to a false color. Defines a band of luminance values
/// (in IRE units, 0-100+) and the RGBA color used to represent that band in the overlay.
public struct FalseColorRange: Identifiable, Equatable {
    public let id = UUID()
    /// Lower bound of the IRE range (inclusive). 0-100+ scale.
    public var lowerIRE: Float
    /// Upper bound of the IRE range (exclusive). 0-100+ scale.
    public var upperIRE: Float
    /// RGBA color for this range (linear, 0.0-1.0 per component).
    public var color: SIMD4<Float>
    /// Human-readable label for this IRE band (e.g. "Middle Grey", "Skin Tone").
    public var label: String

    public init(lowerIRE: Float, upperIRE: Float, color: SIMD4<Float>, label: String) {
        self.lowerIRE = lowerIRE
        self.upperIRE = upperIRE
        self.color = color
        self.label = label
    }

    /// Convenience: SwiftUI Color from the SIMD4 RGBA.
    public var swiftUIColor: Color {
        Color(
            red: Double(color.x),
            green: Double(color.y),
            blue: Double(color.z),
            opacity: Double(color.w)
        )
    }

    public static func == (lhs: FalseColorRange, rhs: FalseColorRange) -> Bool {
        lhs.lowerIRE == rhs.lowerIRE &&
        lhs.upperIRE == rhs.upperIRE &&
        lhs.color == rhs.color &&
        lhs.label == rhs.label
    }
}

// MARK: - False Color Configuration

/// Observable configuration for the false color scope. Holds the active IRE-to-color mapping,
/// selected preset, overlay opacity, and edit mode state. Publishes changes for SwiftUI binding.
public final class FalseColorConfig: ObservableObject {
    /// Active IRE ranges and their false colors, sorted by lowerIRE ascending.
    @Published public var ranges: [FalseColorRange]
    /// Currently selected preset.
    @Published public var selectedPreset: FalseColorPreset {
        didSet {
            if selectedPreset != oldValue {
                loadPreset(selectedPreset)
            }
        }
    }
    /// When true, the legend shows editable controls for range boundaries.
    @Published public var isEditMode: Bool = false
    /// Overlay blend opacity (0.0 = transparent, 1.0 = fully opaque false color).
    @Published public var opacity: Float = 1.0
    /// Show the original image blended underneath at (1 - opacity).
    @Published public var showOriginalBlend: Bool = false

    private let logCategory = "Scopes.FalseColor"

    public init(preset: FalseColorPreset = .defaultPreset) {
        self.selectedPreset = preset
        self.ranges = []
        loadPreset(preset)
    }

    /// Load the IRE range definitions for the given preset.
    public func loadPreset(_ preset: FalseColorPreset) {
        switch preset {
        case .defaultPreset:
            ranges = Self.defaultRanges()
        case .arri:
            ranges = Self.arriRanges()
        case .red:
            ranges = Self.redRanges()
        case .sony:
            ranges = Self.sonyRanges()
        case .canon:
            ranges = Self.canonRanges()
        case .panasonic:
            ranges = Self.panasonicRanges()
        case .bmd:
            ranges = Self.bmdRanges()
        case .aces:
            ranges = Self.acesRanges()
        case .ebu:
            ranges = Self.ebuRanges()
        case .smpte:
            ranges = Self.smpteRanges()
        case .custom1, .custom2, .custom3:
            // Custom presets start with default; user edits in-place.
            if ranges.isEmpty {
                ranges = Self.defaultRanges()
            }
        }
    }

    // MARK: - Default Preset (general purpose)

    /// Default false color map: 11 bands covering underexposure through overexposure.
    /// Matches the specification: purple blacks, blue shadows, green middle grey,
    /// yellow-green/orange skin tones, red highlights, pink/magenta overexposure.
    public static func defaultRanges() -> [FalseColorRange] {
        [
            FalseColorRange(lowerIRE: -Float.infinity, upperIRE: 2,
                            color: SIMD4<Float>(0.35, 0.0, 0.55, 1.0),
                            label: "Clipped Blacks"),
            FalseColorRange(lowerIRE: 2, upperIRE: 18,
                            color: SIMD4<Float>(0.1, 0.15, 0.85, 1.0),
                            label: "Shadows"),
            FalseColorRange(lowerIRE: 18, upperIRE: 38,
                            color: SIMD4<Float>(0.0, 0.75, 0.85, 1.0),
                            label: "Dark Midtones"),
            FalseColorRange(lowerIRE: 38, upperIRE: 42,
                            color: SIMD4<Float>(0.0, 0.78, 0.15, 1.0),
                            label: "Middle Grey"),
            FalseColorRange(lowerIRE: 42, upperIRE: 50,
                            color: SIMD4<Float>(0.45, 0.85, 0.2, 1.0),
                            label: "Midtones"),
            FalseColorRange(lowerIRE: 50, upperIRE: 57,
                            color: SIMD4<Float>(0.65, 0.82, 0.1, 1.0),
                            label: "Skin Tone Low"),
            FalseColorRange(lowerIRE: 57, upperIRE: 70,
                            color: SIMD4<Float>(0.92, 0.82, 0.05, 1.0),
                            label: "Bright Midtones"),
            FalseColorRange(lowerIRE: 70, upperIRE: 80,
                            color: SIMD4<Float>(0.95, 0.55, 0.05, 1.0),
                            label: "Skin Tone High"),
            FalseColorRange(lowerIRE: 80, upperIRE: 90,
                            color: SIMD4<Float>(0.92, 0.12, 0.08, 1.0),
                            label: "Hot Highlights"),
            FalseColorRange(lowerIRE: 90, upperIRE: 100,
                            color: SIMD4<Float>(0.95, 0.2, 0.75, 1.0),
                            label: "Overexposed"),
            FalseColorRange(lowerIRE: 100, upperIRE: Float.infinity,
                            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                            label: "Clipped Highlights"),
        ]
    }

    // MARK: - ARRI Preset

    /// ARRI false color: optimized for LogC / ALEXA sensor. Emphasizes 18% grey at ~38 IRE,
    /// skin tones 42-70 IRE, and tight clipping indicators at extremes.
    public static func arriRanges() -> [FalseColorRange] {
        [
            FalseColorRange(lowerIRE: -Float.infinity, upperIRE: 1,
                            color: SIMD4<Float>(0.25, 0.0, 0.45, 1.0),
                            label: "Black Clip"),
            FalseColorRange(lowerIRE: 1, upperIRE: 10,
                            color: SIMD4<Float>(0.08, 0.08, 0.65, 1.0),
                            label: "Near Black"),
            FalseColorRange(lowerIRE: 10, upperIRE: 20,
                            color: SIMD4<Float>(0.0, 0.3, 0.8, 1.0),
                            label: "Fill Shadow"),
            FalseColorRange(lowerIRE: 20, upperIRE: 35,
                            color: SIMD4<Float>(0.0, 0.65, 0.75, 1.0),
                            label: "Low Midtone"),
            FalseColorRange(lowerIRE: 35, upperIRE: 44,
                            color: SIMD4<Float>(0.0, 0.72, 0.18, 1.0),
                            label: "18% Grey"),
            FalseColorRange(lowerIRE: 44, upperIRE: 55,
                            color: SIMD4<Float>(0.5, 0.82, 0.2, 1.0),
                            label: "Key Midtone"),
            FalseColorRange(lowerIRE: 55, upperIRE: 65,
                            color: SIMD4<Float>(0.75, 0.78, 0.08, 1.0),
                            label: "Skin Tone"),
            FalseColorRange(lowerIRE: 65, upperIRE: 78,
                            color: SIMD4<Float>(0.92, 0.6, 0.05, 1.0),
                            label: "Highlight"),
            FalseColorRange(lowerIRE: 78, upperIRE: 90,
                            color: SIMD4<Float>(0.9, 0.15, 0.1, 1.0),
                            label: "Hot"),
            FalseColorRange(lowerIRE: 90, upperIRE: 100,
                            color: SIMD4<Float>(0.9, 0.18, 0.7, 1.0),
                            label: "Super White"),
            FalseColorRange(lowerIRE: 100, upperIRE: Float.infinity,
                            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                            label: "White Clip"),
        ]
    }

    // MARK: - RED Preset

    /// RED false color: optimized for REDcode RAW / IPP2 workflow.
    /// Wider highlight range; aggressive clipping markers.
    public static func redRanges() -> [FalseColorRange] {
        [
            FalseColorRange(lowerIRE: -Float.infinity, upperIRE: 2,
                            color: SIMD4<Float>(0.3, 0.0, 0.5, 1.0),
                            label: "Crushed"),
            FalseColorRange(lowerIRE: 2, upperIRE: 15,
                            color: SIMD4<Float>(0.1, 0.1, 0.75, 1.0),
                            label: "Deep Shadow"),
            FalseColorRange(lowerIRE: 15, upperIRE: 30,
                            color: SIMD4<Float>(0.0, 0.55, 0.8, 1.0),
                            label: "Shadow"),
            FalseColorRange(lowerIRE: 30, upperIRE: 42,
                            color: SIMD4<Float>(0.0, 0.75, 0.25, 1.0),
                            label: "Low Mid / Grey"),
            FalseColorRange(lowerIRE: 42, upperIRE: 55,
                            color: SIMD4<Float>(0.5, 0.8, 0.15, 1.0),
                            label: "Midtone"),
            FalseColorRange(lowerIRE: 55, upperIRE: 68,
                            color: SIMD4<Float>(0.85, 0.78, 0.05, 1.0),
                            label: "Skin / Upper Mid"),
            FalseColorRange(lowerIRE: 68, upperIRE: 82,
                            color: SIMD4<Float>(0.92, 0.52, 0.05, 1.0),
                            label: "Highlight"),
            FalseColorRange(lowerIRE: 82, upperIRE: 92,
                            color: SIMD4<Float>(0.88, 0.12, 0.1, 1.0),
                            label: "Hot Highlight"),
            FalseColorRange(lowerIRE: 92, upperIRE: 100,
                            color: SIMD4<Float>(0.92, 0.2, 0.7, 1.0),
                            label: "Near Clip"),
            FalseColorRange(lowerIRE: 100, upperIRE: Float.infinity,
                            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                            label: "Clipped"),
        ]
    }

    // MARK: - Sony Preset

    /// Sony false color: S-Log3/S-Gamut3 optimized. 18% grey ~41 IRE in S-Log3.
    public static func sonyRanges() -> [FalseColorRange] {
        [
            FalseColorRange(lowerIRE: -Float.infinity, upperIRE: 3,
                            color: SIMD4<Float>(0.3, 0.0, 0.5, 1.0),
                            label: "Black Clip"),
            FalseColorRange(lowerIRE: 3, upperIRE: 16,
                            color: SIMD4<Float>(0.08, 0.12, 0.72, 1.0),
                            label: "Low Shadow"),
            FalseColorRange(lowerIRE: 16, upperIRE: 32,
                            color: SIMD4<Float>(0.0, 0.58, 0.78, 1.0),
                            label: "Shadow"),
            FalseColorRange(lowerIRE: 32, upperIRE: 45,
                            color: SIMD4<Float>(0.0, 0.72, 0.2, 1.0),
                            label: "18% Grey"),
            FalseColorRange(lowerIRE: 45, upperIRE: 55,
                            color: SIMD4<Float>(0.5, 0.82, 0.18, 1.0),
                            label: "Midtone"),
            FalseColorRange(lowerIRE: 55, upperIRE: 65,
                            color: SIMD4<Float>(0.8, 0.78, 0.06, 1.0),
                            label: "Skin Tone"),
            FalseColorRange(lowerIRE: 65, upperIRE: 78,
                            color: SIMD4<Float>(0.92, 0.58, 0.05, 1.0),
                            label: "Highlight"),
            FalseColorRange(lowerIRE: 78, upperIRE: 90,
                            color: SIMD4<Float>(0.88, 0.12, 0.1, 1.0),
                            label: "Hot"),
            FalseColorRange(lowerIRE: 90, upperIRE: 100,
                            color: SIMD4<Float>(0.92, 0.2, 0.72, 1.0),
                            label: "Over"),
            FalseColorRange(lowerIRE: 100, upperIRE: Float.infinity,
                            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                            label: "Clip"),
        ]
    }

    // MARK: - Canon Preset

    /// Canon false color: C-Log2/C-Log3 workflow. Middle grey ~39 IRE in C-Log2.
    public static func canonRanges() -> [FalseColorRange] {
        [
            FalseColorRange(lowerIRE: -Float.infinity, upperIRE: 2,
                            color: SIMD4<Float>(0.28, 0.0, 0.48, 1.0),
                            label: "Black Clip"),
            FalseColorRange(lowerIRE: 2, upperIRE: 14,
                            color: SIMD4<Float>(0.08, 0.1, 0.7, 1.0),
                            label: "Deep Shadow"),
            FalseColorRange(lowerIRE: 14, upperIRE: 28,
                            color: SIMD4<Float>(0.0, 0.5, 0.78, 1.0),
                            label: "Shadow"),
            FalseColorRange(lowerIRE: 28, upperIRE: 44,
                            color: SIMD4<Float>(0.0, 0.72, 0.22, 1.0),
                            label: "Middle Grey"),
            FalseColorRange(lowerIRE: 44, upperIRE: 56,
                            color: SIMD4<Float>(0.5, 0.82, 0.18, 1.0),
                            label: "Midtone"),
            FalseColorRange(lowerIRE: 56, upperIRE: 68,
                            color: SIMD4<Float>(0.82, 0.78, 0.06, 1.0),
                            label: "Skin / Warm Mid"),
            FalseColorRange(lowerIRE: 68, upperIRE: 82,
                            color: SIMD4<Float>(0.92, 0.55, 0.05, 1.0),
                            label: "Highlight"),
            FalseColorRange(lowerIRE: 82, upperIRE: 92,
                            color: SIMD4<Float>(0.9, 0.12, 0.08, 1.0),
                            label: "Hot"),
            FalseColorRange(lowerIRE: 92, upperIRE: 100,
                            color: SIMD4<Float>(0.92, 0.2, 0.72, 1.0),
                            label: "Over"),
            FalseColorRange(lowerIRE: 100, upperIRE: Float.infinity,
                            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                            label: "White Clip"),
        ]
    }

    // MARK: - Panasonic Preset

    /// Panasonic false color: V-Log/V-Gamut workflow. 18% grey ~42 IRE in V-Log.
    public static func panasonicRanges() -> [FalseColorRange] {
        [
            FalseColorRange(lowerIRE: -Float.infinity, upperIRE: 2,
                            color: SIMD4<Float>(0.3, 0.0, 0.52, 1.0),
                            label: "Crushed"),
            FalseColorRange(lowerIRE: 2, upperIRE: 16,
                            color: SIMD4<Float>(0.08, 0.1, 0.72, 1.0),
                            label: "Shadow"),
            FalseColorRange(lowerIRE: 16, upperIRE: 34,
                            color: SIMD4<Float>(0.0, 0.6, 0.8, 1.0),
                            label: "Low Mid"),
            FalseColorRange(lowerIRE: 34, upperIRE: 48,
                            color: SIMD4<Float>(0.0, 0.75, 0.2, 1.0),
                            label: "Middle Grey"),
            FalseColorRange(lowerIRE: 48, upperIRE: 58,
                            color: SIMD4<Float>(0.5, 0.82, 0.18, 1.0),
                            label: "Midtone"),
            FalseColorRange(lowerIRE: 58, upperIRE: 70,
                            color: SIMD4<Float>(0.82, 0.78, 0.06, 1.0),
                            label: "Skin Tone"),
            FalseColorRange(lowerIRE: 70, upperIRE: 82,
                            color: SIMD4<Float>(0.92, 0.55, 0.05, 1.0),
                            label: "Highlight"),
            FalseColorRange(lowerIRE: 82, upperIRE: 92,
                            color: SIMD4<Float>(0.88, 0.12, 0.1, 1.0),
                            label: "Hot"),
            FalseColorRange(lowerIRE: 92, upperIRE: 100,
                            color: SIMD4<Float>(0.92, 0.2, 0.72, 1.0),
                            label: "Over"),
            FalseColorRange(lowerIRE: 100, upperIRE: Float.infinity,
                            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                            label: "Clip"),
        ]
    }

    // MARK: - Blackmagic Design Preset

    /// BMD false color: Blackmagic Film / Gen5 Color Science. 18% grey ~38 IRE.
    public static func bmdRanges() -> [FalseColorRange] {
        [
            FalseColorRange(lowerIRE: -Float.infinity, upperIRE: 2,
                            color: SIMD4<Float>(0.3, 0.0, 0.5, 1.0),
                            label: "Black Clip"),
            FalseColorRange(lowerIRE: 2, upperIRE: 12,
                            color: SIMD4<Float>(0.08, 0.08, 0.68, 1.0),
                            label: "Under"),
            FalseColorRange(lowerIRE: 12, upperIRE: 28,
                            color: SIMD4<Float>(0.0, 0.5, 0.78, 1.0),
                            label: "Shadow"),
            FalseColorRange(lowerIRE: 28, upperIRE: 38,
                            color: SIMD4<Float>(0.0, 0.7, 0.65, 1.0),
                            label: "Low Midtone"),
            FalseColorRange(lowerIRE: 38, upperIRE: 48,
                            color: SIMD4<Float>(0.0, 0.72, 0.18, 1.0),
                            label: "Middle Grey"),
            FalseColorRange(lowerIRE: 48, upperIRE: 58,
                            color: SIMD4<Float>(0.55, 0.82, 0.18, 1.0),
                            label: "Midtone"),
            FalseColorRange(lowerIRE: 58, upperIRE: 68,
                            color: SIMD4<Float>(0.82, 0.78, 0.06, 1.0),
                            label: "Skin Tone"),
            FalseColorRange(lowerIRE: 68, upperIRE: 80,
                            color: SIMD4<Float>(0.92, 0.55, 0.05, 1.0),
                            label: "Highlight"),
            FalseColorRange(lowerIRE: 80, upperIRE: 92,
                            color: SIMD4<Float>(0.9, 0.12, 0.08, 1.0),
                            label: "Hot"),
            FalseColorRange(lowerIRE: 92, upperIRE: 100,
                            color: SIMD4<Float>(0.92, 0.2, 0.72, 1.0),
                            label: "Over"),
            FalseColorRange(lowerIRE: 100, upperIRE: Float.infinity,
                            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                            label: "White Clip"),
        ]
    }

    // MARK: - ACES Preset

    /// ACES false color: Academy Color Encoding System. Wider dynamic range focus.
    public static func acesRanges() -> [FalseColorRange] {
        [
            FalseColorRange(lowerIRE: -Float.infinity, upperIRE: 1,
                            color: SIMD4<Float>(0.28, 0.0, 0.45, 1.0),
                            label: "Below Black"),
            FalseColorRange(lowerIRE: 1, upperIRE: 8,
                            color: SIMD4<Float>(0.08, 0.08, 0.65, 1.0),
                            label: "Near Black"),
            FalseColorRange(lowerIRE: 8, upperIRE: 22,
                            color: SIMD4<Float>(0.0, 0.35, 0.78, 1.0),
                            label: "Shadow"),
            FalseColorRange(lowerIRE: 22, upperIRE: 35,
                            color: SIMD4<Float>(0.0, 0.62, 0.78, 1.0),
                            label: "Low Midtone"),
            FalseColorRange(lowerIRE: 35, upperIRE: 47,
                            color: SIMD4<Float>(0.0, 0.72, 0.2, 1.0),
                            label: "18% Grey"),
            FalseColorRange(lowerIRE: 47, upperIRE: 58,
                            color: SIMD4<Float>(0.5, 0.82, 0.18, 1.0),
                            label: "Midtone"),
            FalseColorRange(lowerIRE: 58, upperIRE: 70,
                            color: SIMD4<Float>(0.82, 0.78, 0.06, 1.0),
                            label: "High Mid / Skin"),
            FalseColorRange(lowerIRE: 70, upperIRE: 85,
                            color: SIMD4<Float>(0.92, 0.55, 0.05, 1.0),
                            label: "Highlight"),
            FalseColorRange(lowerIRE: 85, upperIRE: 95,
                            color: SIMD4<Float>(0.88, 0.12, 0.1, 1.0),
                            label: "Specular"),
            FalseColorRange(lowerIRE: 95, upperIRE: 100,
                            color: SIMD4<Float>(0.92, 0.2, 0.72, 1.0),
                            label: "Over"),
            FalseColorRange(lowerIRE: 100, upperIRE: Float.infinity,
                            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                            label: "Clip"),
        ]
    }

    // MARK: - EBU Preset

    /// EBU false color: European Broadcasting Union standards. Strict broadcast safe regions.
    /// EBU R 103: -1 to 103 IRE legal range; 0-100 nominal.
    public static func ebuRanges() -> [FalseColorRange] {
        [
            FalseColorRange(lowerIRE: -Float.infinity, upperIRE: 0,
                            color: SIMD4<Float>(0.3, 0.0, 0.5, 1.0),
                            label: "Sub-Black"),
            FalseColorRange(lowerIRE: 0, upperIRE: 5,
                            color: SIMD4<Float>(0.08, 0.08, 0.68, 1.0),
                            label: "Black"),
            FalseColorRange(lowerIRE: 5, upperIRE: 20,
                            color: SIMD4<Float>(0.0, 0.35, 0.78, 1.0),
                            label: "Shadow"),
            FalseColorRange(lowerIRE: 20, upperIRE: 38,
                            color: SIMD4<Float>(0.0, 0.6, 0.78, 1.0),
                            label: "Low Mid"),
            FalseColorRange(lowerIRE: 38, upperIRE: 50,
                            color: SIMD4<Float>(0.0, 0.72, 0.2, 1.0),
                            label: "Reference Grey"),
            FalseColorRange(lowerIRE: 50, upperIRE: 65,
                            color: SIMD4<Float>(0.5, 0.82, 0.18, 1.0),
                            label: "Midtone"),
            FalseColorRange(lowerIRE: 65, upperIRE: 75,
                            color: SIMD4<Float>(0.82, 0.78, 0.06, 1.0),
                            label: "Skin / Warm"),
            FalseColorRange(lowerIRE: 75, upperIRE: 90,
                            color: SIMD4<Float>(0.92, 0.55, 0.05, 1.0),
                            label: "Highlight"),
            FalseColorRange(lowerIRE: 90, upperIRE: 100,
                            color: SIMD4<Float>(0.88, 0.12, 0.1, 1.0),
                            label: "Peak White"),
            FalseColorRange(lowerIRE: 100, upperIRE: 104,
                            color: SIMD4<Float>(0.92, 0.2, 0.72, 1.0),
                            label: "Super White"),
            FalseColorRange(lowerIRE: 104, upperIRE: Float.infinity,
                            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                            label: "Illegal"),
        ]
    }

    // MARK: - SMPTE Preset

    /// SMPTE false color: Society of Motion Picture and Television Engineers reference levels.
    /// SMPTE RP 219: 0 IRE black, 100 IRE white, 7.5 IRE setup (NTSC).
    public static func smpteRanges() -> [FalseColorRange] {
        [
            FalseColorRange(lowerIRE: -Float.infinity, upperIRE: 0,
                            color: SIMD4<Float>(0.3, 0.0, 0.5, 1.0),
                            label: "Sub-Black"),
            FalseColorRange(lowerIRE: 0, upperIRE: 7.5,
                            color: SIMD4<Float>(0.08, 0.08, 0.65, 1.0),
                            label: "Setup / Pedestal"),
            FalseColorRange(lowerIRE: 7.5, upperIRE: 20,
                            color: SIMD4<Float>(0.0, 0.35, 0.78, 1.0),
                            label: "Shadow"),
            FalseColorRange(lowerIRE: 20, upperIRE: 38,
                            color: SIMD4<Float>(0.0, 0.6, 0.78, 1.0),
                            label: "Low Midtone"),
            FalseColorRange(lowerIRE: 38, upperIRE: 50,
                            color: SIMD4<Float>(0.0, 0.72, 0.2, 1.0),
                            label: "Middle Grey"),
            FalseColorRange(lowerIRE: 50, upperIRE: 65,
                            color: SIMD4<Float>(0.5, 0.82, 0.18, 1.0),
                            label: "Midtone"),
            FalseColorRange(lowerIRE: 65, upperIRE: 75,
                            color: SIMD4<Float>(0.82, 0.78, 0.06, 1.0),
                            label: "Skin Tone"),
            FalseColorRange(lowerIRE: 75, upperIRE: 90,
                            color: SIMD4<Float>(0.92, 0.55, 0.05, 1.0),
                            label: "Highlight"),
            FalseColorRange(lowerIRE: 90, upperIRE: 100,
                            color: SIMD4<Float>(0.88, 0.12, 0.1, 1.0),
                            label: "Peak White"),
            FalseColorRange(lowerIRE: 100, upperIRE: 110,
                            color: SIMD4<Float>(0.92, 0.2, 0.72, 1.0),
                            label: "Super White"),
            FalseColorRange(lowerIRE: 110, upperIRE: Float.infinity,
                            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                            label: "Illegal"),
        ]
    }

    // MARK: - GPU Buffer Generation

    /// Generates a flat array of (lowerIRE, upperIRE, R, G, B, A) floats suitable for upload
    /// to a Metal buffer. Each range occupies 6 floats. Terminated by a sentinel range.
    public func metalRangeBuffer() -> [Float] {
        var buf: [Float] = []
        for range in ranges {
            let lower = range.lowerIRE.isInfinite ? -1.0 : range.lowerIRE / 100.0
            let upper = range.upperIRE.isInfinite ? 2.0 : range.upperIRE / 100.0
            buf.append(lower)
            buf.append(upper)
            buf.append(range.color.x)
            buf.append(range.color.y)
            buf.append(range.color.z)
            buf.append(range.color.w)
        }
        return buf
    }
}

// MARK: - False Color Scope Model

/// False color scope: receives texture updates and produces false-color mapped output.
/// Conforms to ScopeTextureUpdatable for integration with MasterPipeline.
public final class FalseColorScope: ScopeTextureUpdatable {
    public private(set) var currentTexture: MTLTexture?
    public let config: FalseColorConfig

    public init(config: FalseColorConfig = FalseColorConfig()) {
        self.config = config
    }

    public func update(texture: MTLTexture?) {
        currentTexture = texture
    }
}

// MARK: - Metal false color compute kernel (inline source)

/// Metal Shading Language source for the false color compute kernel.
/// Converts input texture luminance to IRE, maps through the range LUT, and writes
/// the false color (or blended) result to the output texture.
private let falseColorShaderSource = """
#include <metal_stdlib>
using namespace metal;

// BT.709 luminance coefficients.
constant float kLumR = 0.2126;
constant float kLumG = 0.7152;
constant float kLumB = 0.0722;

// Maximum number of false color ranges supported per dispatch.
constant uint kMaxRanges = 32u;

// Per-range data: (lowerNorm, upperNorm, R, G, B, A). 6 floats per range.
struct FalseColorParams {
    uint rangeCount;
    float opacity;       // 0.0 = show original, 1.0 = full false color
    uint pad0;
    uint pad1;
};

// Fullscreen triangle vertex shader for blit pass.
struct CopyVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CopyVertexOut false_color_copy_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    CopyVertexOut out;
    out.position = float4(uv * 2.0 - 1.0, 0, 1);
    out.uv = float2(uv.x, 1.0 - uv.y);
    return out;
}

fragment float4 false_color_copy_fragment(CopyVertexOut in [[stage_in]],
                                          texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    return src.sample(s, in.uv);
}

// Compute kernel: reads source texture, computes luminance → IRE, looks up false color range,
// writes result (with optional original blend) to output texture.
kernel void false_color_map(
    texture2d<float, access::read>  srcTexture  [[texture(0)]],
    texture2d<float, access::write> dstTexture  [[texture(1)]],
    device const float*             rangeData   [[buffer(0)]],
    constant FalseColorParams&      params      [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = srcTexture.get_width();
    uint h = srcTexture.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float4 pixel = srcTexture.read(gid);
    float lum = kLumR * pixel.r + kLumG * pixel.g + kLumB * pixel.b;

    // Map luminance (0.0-1.0 linear) to false color via range lookup.
    float4 falseColor = float4(0.5, 0.5, 0.5, 1.0); // fallback grey
    uint count = min(params.rangeCount, kMaxRanges);
    for (uint i = 0u; i < count; i++) {
        uint base = i * 6u;
        float lower = rangeData[base + 0u];
        float upper = rangeData[base + 1u];
        if (lum >= lower && lum < upper) {
            falseColor = float4(rangeData[base + 2u],
                                rangeData[base + 3u],
                                rangeData[base + 4u],
                                rangeData[base + 5u]);
            break;
        }
    }

    // Blend: mix original pixel with false color based on opacity.
    float alpha = params.opacity;
    float4 result = mix(pixel, falseColor, alpha);
    result.a = 1.0;
    dstTexture.write(result, gid);
}

// Placeholder: dark gradient background when no source texture is available.
vertex CopyVertexOut false_color_placeholder_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    CopyVertexOut out;
    out.position = float4(uv * 2.0 - 1.0, 0, 1);
    out.uv = uv;
    return out;
}

fragment float4 false_color_placeholder_fragment(CopyVertexOut in [[stage_in]]) {
    float t = in.uv.y;
    float3 dark = float3(0.06, 0.06, 0.08);
    float3 top  = float3(0.10, 0.10, 0.14);
    float3 c = mix(dark, top, t);
    return float4(c, 1.0);
}
"""

// MARK: - False Color Metal View (CAMetalLayer-backed)

/// NSView that hosts a CAMetalLayer for rendering false-color mapped video frames.
/// Runs the false_color_map compute kernel on each input texture, then blits the result
/// to the layer's drawable. Timer-driven at 15fps to match other scope display views.
public final class FalseColorDisplayLayerView: NSView {
    private var metalLayer: CAMetalLayer!
    private var displayTimer: Timer?
    private var metalDevice: MTLDevice?

    // Pipeline states
    private var computePipelineState: MTLComputePipelineState?
    private var copyPipelineState: MTLRenderPipelineState?
    private var placeholderPipelineState: MTLRenderPipelineState?

    // GPU buffers for range data
    private var rangeBuffer: MTLBuffer?
    private var paramsBuffer: MTLBuffer?

    // Intermediate texture for compute output
    private var outputTexture: MTLTexture?
    private var lastOutputSize: (Int, Int) = (0, 0)

    /// The pipeline to read source textures from.
    var pipeline: MasterPipeline?
    /// False color configuration (ranges, opacity, preset).
    var falseColorConfig: FalseColorConfig?
    /// Scope type used to fetch the source texture from the pipeline.
    var scopeType: ScopeType = .waveform

    override public init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        guard let device = MetalEngine.shared?.device else { return }
        metalDevice = device

        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.displaySyncEnabled = true

        wantsLayer = true
        layer = metalLayer

        setupPipelines(device: device)

        // Allocate GPU buffers for false color range data (max 32 ranges * 6 floats).
        let maxRangeBytes = 32 * 6 * MemoryLayout<Float>.stride
        rangeBuffer = device.makeBuffer(length: maxRangeBytes, options: .storageModeShared)

        let paramsSize = MemoryLayout<UInt32>.stride * 4 // rangeCount, opacity (as float bits), pad, pad
        paramsBuffer = device.makeBuffer(length: paramsSize, options: .storageModeShared)

        // 15fps display timer (matches ScopeDisplayLayerView cadence).
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.refreshDisplay()
        }
    }

    deinit {
        displayTimer?.invalidate()
    }

    public override func layout() {
        super.layout()
        guard let metalLayer = metalLayer else { return }
        metalLayer.frame = bounds
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screen = window?.screen ?? NSScreen.main {
            metalLayer?.contentsScale = screen.backingScaleFactor
        }
    }

    // MARK: - Pipeline Setup

    private func setupPipelines(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: falseColorShaderSource, options: nil) else {
            return
        }

        // Compute pipeline: false_color_map kernel.
        if let computeFn = library.makeFunction(name: "false_color_map") {
            computePipelineState = try? device.makeComputePipelineState(function: computeFn)
        }

        // Render pipeline: fullscreen blit from compute output to drawable.
        if let vtx = library.makeFunction(name: "false_color_copy_vertex"),
           let frag = library.makeFunction(name: "false_color_copy_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtx
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            copyPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // Placeholder pipeline: dark gradient when no input.
        if let vtx = library.makeFunction(name: "false_color_placeholder_vertex"),
           let frag = library.makeFunction(name: "false_color_placeholder_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtx
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            placeholderPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    // MARK: - Output Texture Management

    /// Ensure the intermediate compute output texture matches the source dimensions.
    private func ensureOutputTexture(width: Int, height: Int, device: MTLDevice) {
        if lastOutputSize.0 == width && lastOutputSize.1 == height, outputTexture != nil {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        outputTexture = device.makeTexture(descriptor: desc)
        lastOutputSize = (width, height)
    }

    // MARK: - Frame Refresh

    private func refreshDisplay() {
        guard let metalLayer = metalLayer,
              metalLayer.drawableSize.width > 0 && metalLayer.drawableSize.height > 0,
              let drawable = metalLayer.nextDrawable(),
              let device = metalDevice,
              let cmdBuf = MetalEngine.shared?.commandQueue.makeCommandBuffer() else { return }

        // Try to get source texture from pipeline.
        let sourceTexture: MTLTexture?
        if let pipeline = pipeline {
            sourceTexture = pipeline.scopeTexture(for: scopeType)
        } else {
            sourceTexture = nil
        }

        guard let source = sourceTexture,
              let computePipeline = computePipelineState,
              let copyPipeline = copyPipelineState,
              let config = falseColorConfig,
              let rangeBuf = rangeBuffer,
              let paramsBuf = paramsBuffer else {
            // No source — render placeholder.
            drawPlaceholder(cmdBuf: cmdBuf, drawable: drawable)
            return
        }

        let srcWidth = source.width
        let srcHeight = source.height
        ensureOutputTexture(width: srcWidth, height: srcHeight, device: device)

        guard let outTex = outputTexture else {
            drawPlaceholder(cmdBuf: cmdBuf, drawable: drawable)
            return
        }

        // Upload range data to GPU buffer.
        let rangeData = config.metalRangeBuffer()
        let rangeByteCount = rangeData.count * MemoryLayout<Float>.stride
        let rangeBufCapacity = rangeBuf.length
        if rangeByteCount <= rangeBufCapacity {
            memcpy(rangeBuf.contents(), rangeData, rangeByteCount)
        }

        // Upload params.
        let rangeCount = UInt32(config.ranges.count)
        let opacity = config.opacity
        let paramsPtr = paramsBuf.contents().bindMemory(to: UInt32.self, capacity: 4)
        paramsPtr[0] = rangeCount
        // Store opacity as float bits in the second uint slot (struct layout matches Metal side).
        withUnsafeBytes(of: opacity) { bytes in
            (paramsBuf.contents() + MemoryLayout<UInt32>.stride).copyMemory(
                from: bytes.baseAddress!, byteCount: MemoryLayout<Float>.stride
            )
        }
        paramsPtr[2] = 0 // pad
        paramsPtr[3] = 0 // pad

        // Dispatch compute kernel: false_color_map.
        guard let compEncoder = cmdBuf.makeComputeCommandEncoder() else {
            drawPlaceholder(cmdBuf: cmdBuf, drawable: drawable)
            return
        }
        compEncoder.setComputePipelineState(computePipeline)
        compEncoder.setTexture(source, index: 0)
        compEncoder.setTexture(outTex, index: 1)
        compEncoder.setBuffer(rangeBuf, offset: 0, index: 0)
        compEncoder.setBuffer(paramsBuf, offset: 0, index: 1)

        let threadgroupSize = MTLSize(
            width: min(16, computePipeline.maxTotalThreadsPerThreadgroup),
            height: min(16, computePipeline.maxTotalThreadsPerThreadgroup / 16),
            depth: 1
        )
        let threadgroupCount = MTLSize(
            width: (srcWidth + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (srcHeight + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        compEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        compEncoder.endEncoding()

        // Blit compute output to drawable.
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)

        guard let renderEncoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            drawPlaceholder(cmdBuf: cmdBuf, drawable: drawable)
            return
        }
        renderEncoder.setRenderPipelineState(copyPipeline)
        renderEncoder.setFragmentTexture(outTex, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    private func drawPlaceholder(cmdBuf: MTLCommandBuffer, drawable: CAMetalDrawable) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)

        guard let pipeline = placeholderPipelineState,
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            cmdBuf.commit()
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}

// MARK: - SwiftUI NSViewRepresentable for the Metal layer

/// NSViewRepresentable wrapper for FalseColorDisplayLayerView. Bridges the CAMetalLayer-backed
/// view into SwiftUI and syncs pipeline, config, and scope type on updates.
private struct FalseColorDisplayRepresentable: NSViewRepresentable {
    let pipeline: MasterPipeline?
    let config: FalseColorConfig
    let scopeType: ScopeType

    func makeNSView(context: Context) -> FalseColorDisplayLayerView {
        let view = FalseColorDisplayLayerView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.pipeline = pipeline
        view.falseColorConfig = config
        view.scopeType = scopeType
        return view
    }

    func updateNSView(_ nsView: FalseColorDisplayLayerView, context: Context) {
        nsView.pipeline = pipeline
        nsView.falseColorConfig = config
        nsView.scopeType = scopeType
    }
}

// MARK: - False Color Overlay View (Legend + Controls Strip)

/// Overlay view showing the false color legend bar, preset picker, and opacity control.
/// Designed as a strip along the bottom of the scope, matching the AJA theme.
public struct FalseColorOverlayView: View {
    @ObservedObject var config: FalseColorConfig

    public init(config: FalseColorConfig) {
        self.config = config
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Controls bar
            HStack(spacing: 10) {
                // Preset picker
                Picker("Preset", selection: $config.selectedPreset) {
                    ForEach(FalseColorPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 140)
                .foregroundColor(AJATheme.primaryText)

                Divider()
                    .frame(height: 16)
                    .background(AJATheme.divider)

                // Opacity slider
                HStack(spacing: 4) {
                    Text("Opacity")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(AJATheme.secondaryText)
                    Slider(value: Binding(
                        get: { Double(config.opacity) },
                        set: { config.opacity = Float($0) }
                    ), in: 0.0...1.0, step: 0.05)
                    .frame(width: 80)
                    Text(String(format: "%.0f%%", config.opacity * 100))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundColor(AJATheme.tertiaryText)
                        .frame(width: 30, alignment: .trailing)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AJATheme.panelBackground.opacity(0.85))

            // Legend bar: colored blocks with IRE labels
            legendBar
        }
    }

    /// Horizontal strip of colored blocks representing each IRE range.
    private var legendBar: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let ranges = config.ranges
            let displayRanges = ranges.filter { !$0.lowerIRE.isInfinite && !$0.upperIRE.isInfinite }
            let allRanges = ranges

            HStack(spacing: 0) {
                ForEach(allRanges) { range in
                    legendBlock(range: range, totalWidth: totalWidth, allRanges: allRanges)
                }
            }
        }
        .frame(height: 28)
        .background(AJATheme.statusBarBackground)
    }

    /// Single colored block in the legend strip.
    private func legendBlock(range: FalseColorRange, totalWidth: CGFloat, allRanges: [FalseColorRange]) -> some View {
        let minIRE: Float = 0
        let maxIRE: Float = 110
        let totalIRESpan = maxIRE - minIRE

        let clampedLower = max(minIRE, range.lowerIRE.isInfinite ? minIRE : range.lowerIRE)
        let clampedUpper = min(maxIRE, range.upperIRE.isInfinite ? maxIRE : range.upperIRE)
        let span = max(0, clampedUpper - clampedLower)
        let fraction = CGFloat(span / totalIRESpan)

        return range.swiftUIColor
            .frame(width: max(2, totalWidth * fraction))
            .overlay(
                VStack(spacing: 0) {
                    Text(range.label)
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(.black.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(ireLabelText(range: range))
                        .font(.system(size: 6, weight: .regular, design: .monospaced))
                        .foregroundColor(.black.opacity(0.65))
                        .lineLimit(1)
                }
                .padding(.horizontal, 1)
            )
            .clipped()
    }

    /// Format the IRE range text for the legend label.
    private func ireLabelText(range: FalseColorRange) -> String {
        let lower = range.lowerIRE.isInfinite ? "<0" : String(format: "%.0f", range.lowerIRE)
        let upper = range.upperIRE.isInfinite ? ">100" : String(format: "%.0f", range.upperIRE)
        return "\(lower)-\(upper)"
    }
}

// MARK: - False Color Scope View (main public SwiftUI view)

/// SwiftUI view for the false color scope. Shows the video feed with false color overlay
/// applied via Metal compute kernel, with a legend bar and controls strip.
/// SC-018: Mouse wheel zooms into detail (scale 1x-8x).
public struct FalseColorScopeView: View {
    private let pipeline: MasterPipeline?
    private let scope: FalseColorScope?
    @ObservedObject private var config: FalseColorConfig
    /// Which scope texture to use as the source image for false color mapping.
    private let sourceScope: ScopeType
    @State private var scopeZoom: CGFloat = 1.0
    @State private var scopeOffset: CGSize = .zero

    /// Creates a false color scope view.
    /// - Parameters:
    ///   - pipeline: The MasterPipeline providing video frames. Required for live operation.
    ///   - scope: Optional FalseColorScope for standalone texture updates.
    ///   - config: False color configuration (preset, ranges, opacity). Shared observable.
    ///   - sourceScope: Which pipeline scope texture to use as input (default: .waveform for raw frame).
    public init(
        pipeline: MasterPipeline? = nil,
        scope: FalseColorScope? = nil,
        config: FalseColorConfig = FalseColorConfig(),
        sourceScope: ScopeType = .waveform
    ) {
        self.pipeline = pipeline
        self.scope = scope
        self.config = config
        self.sourceScope = sourceScope
    }

    public var body: some View {
        ZStack {
            // CAMetalLayer-based false color display (compute + blit at 15fps).
            FalseColorDisplayRepresentable(
                pipeline: pipeline,
                config: config,
                scopeType: sourceScope
            )

            // Legend and controls overlay at the bottom.
            FalseColorOverlayView(config: config)

            // Scope label (matches convention of other scope views).
            Text("False Color")
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .scaleEffect(scopeZoom)
        .offset(scopeOffset)
        .scopeZoomOverlay(zoom: $scopeZoom, offset: $scopeOffset)
        .clipped()
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
    }
}

// MARK: - Preview

#if DEBUG
struct FalseColorScopeView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            FalseColorScopeView(config: FalseColorConfig(preset: .defaultPreset))
                .frame(width: 640, height: 400)
                .previewDisplayName("Default Preset")

            FalseColorScopeView(config: FalseColorConfig(preset: .arri))
                .frame(width: 640, height: 400)
                .previewDisplayName("ARRI Preset")

            FalseColorOverlayView(config: FalseColorConfig(preset: .defaultPreset))
                .frame(width: 640, height: 80)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
                .previewDisplayName("Legend Bar")
        }
    }
}
#endif
