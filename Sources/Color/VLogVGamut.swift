import Foundation
import Logging

// MARK: - CS-008: Panasonic VLog and V-Gamut

/// Panasonic V-Log transfer function and V-Gamut color space (CS-008).
/// Reference: Panasonic VARICAM V-Log/V-Gamut whitepaper; antlerpost.com; Colour Science.
/// Normalised 0–1: V-Log code value and linear scene-referred light.
public enum VLogVGamut {

    // MARK: - V-Log constants (0–1 normalised)

    /// Linear segment threshold: below this, OETF is linear.
    public static let linearSegmentCut: Double = 0.01
    /// Log segment threshold: below this, EOTF is linear.
    public static let logSegmentCut: Double = 0.181
    /// Log formula: V = c * log10(L + b) + d for L >= cut1.
    public static let b: Double = 0.00873
    public static let c: Double = 0.241514
    public static let d: Double = 0.598206
    /// Linear segment: V = linearSlope * L + linearOffset for L < cut1.
    public static let linearSlope: Double = 5.6
    public static let linearOffset: Double = 0.125

    // MARK: - V-Log OETF (scene linear → V-Log, 0–1)

    /// Encode one channel: linear [0,1] → V-Log [0,1].
    public static func vLogOETF(_ linear: Double) -> Double {
        let L = max(0, min(1, linear))
        if L < linearSegmentCut {
            return linearSlope * L + linearOffset
        }
        return c * log10(L + b) + d
    }

    /// Decode one channel: V-Log [0,1] → linear [0,1].
    public static func vLogEOTF(_ vLog: Double) -> Double {
        let V = max(0, min(1, vLog))
        if V < logSegmentCut {
            return (V - linearOffset) / linearSlope
        }
        return pow(10, (V - d) / c) - b
    }

    // MARK: - V-Gamut RGB → XYZ (D65, row-major)

    /// 3×3 RGB to XYZ matrix (row-major: rows = X, Y, Z from R,G,B).
    /// Use with gamut_convert kernel: pass this or compose with XYZ→Rec.709/Rec.2020 etc.
    public static let vGamutRGBToXYZ: [Float] = [
        0.679644, 0.152211, 0.1186,
        0.260686, 0.774894, -0.03558,
        -0.00931, -0.004612, 1.10298
    ]
}
