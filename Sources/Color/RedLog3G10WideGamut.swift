import Foundation
import Logging

// MARK: - CS-009: RED Log3G10 and REDWideGamutRGB

/// RED Log3G10 transfer function and REDWideGamutRGB color space (CS-009).
/// Reference: RED white paper "REDWideGamutRGB and Log3G10"; colour-science; IPP2.
/// Normalised 0–1: Log3G10 code value and linear scene-referred light.
public enum RedLog3G10WideGamut {

    // MARK: - Log3G10 constants (0–1 normalised)

    /// Log3G10: V = log10(1 + 9*L). At L=1, V=log10(10)=1.
    public static let linearScale: Double = 9.0

    // MARK: - Log3G10 OETF (scene linear → Log3G10, 0–1)

    /// Encode one channel: linear [0,1] → Log3G10 [0,1]. V = log10(1 + 9*L).
    public static func log3G10OETF(_ linear: Double) -> Double {
        let L = max(0, min(1, linear))
        return log10(1.0 + linearScale * L)
    }

    /// Decode one channel: Log3G10 [0,1] → linear [0,1]. L = (10^V - 1) / 9.
    public static func log3G10EOTF(_ log3G10: Double) -> Double {
        let V = max(0, min(1, log3G10))
        return (pow(10, V) - 1.0) / linearScale
    }

    // MARK: - REDWideGamutRGB RGB → XYZ (D65, row-major)

    /// 3×3 RGB to XYZ matrix (row-major: rows = X, Y, Z from R,G,B).
    /// RED Wide Gamut RGB, D65. Use with gamut_convert kernel for REDWideGamut ↔ Rec.709/Rec.2020/P3/XYZ.
    /// Source: RED white paper; colour-science RED_WIDE_GAMUT_RGB.
    public static let redWideGamutRGBToXYZ: [Float] = [
        0.735275, 0.264725, 0.0,
        0.299340, 0.674897, 0.025763,
        0.156396, 0.050701, 0.792903
    ]
}
