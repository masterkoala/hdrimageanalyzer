import Foundation
import Logging

// MARK: - CS-010: ACEScct and ACEScc transfer functions

/// ACEScc and ACEScct transfer functions (CS-010).
/// References: SMPTE/ACES S-2014-003 (ACEScc), S-2016-001 (ACEScct); colour-science.
/// Normalised 0–1: code value and ACES (scene linear) for use in grading pipelines.
public enum ACEScctACEScc {

    // MARK: - ACEScc constants (S-2014-003)

    /// ACEScc: log segment uses (log2(x) + 9.72) / 17.52; linear segment below 2^-15.
    public static let acesccLogScale: Double = 17.52
    public static let acesccLogOffset: Double = 9.72
    /// Linear segment upper bound (exclusive): 0 < x < 2^-15 uses linear formula.
    public static let acesccLinearSegmentUpperBound: Double = pow(2, -15)
    /// Minimum code value (for x <= 0).
    public static let acesccMinCodeValue: Double = (log2(pow(2, -16)) + acesccLogOffset) / acesccLogScale  // ≈ -0.358447
    /// Code value at 2^-15 (start of log segment).
    public static let acesccLogSegmentStart: Double = (log2(pow(2, -15)) + acesccLogOffset) / acesccLogScale  // (9.72 - 15) / 17.52

    // MARK: - ACEScct constants (S-2016-001)

    /// ACEScct linear segment: x <= X_BRK uses A*x + B.
    public static let acescctXBrk: Double = 0.0078125   // 1/128
    /// Code value break: below this use linear inverse (ACEScct → linear).
    public static let acescctYBrk: Double = 0.155251141552511
    public static let acescctA: Double = 10.5402377416545
    public static let acescctB: Double = 0.0729055341958355

    // MARK: - ACEScc OETF (scene linear → ACEScc, 0–1 normalised)

    /// Encode one channel: linear [0,1] → ACEScc. For x <= 0 returns acesccMinCodeValue; for x < 2^-15 uses linear segment; else (log2(x)+9.72)/17.52.
    public static func acesccOETF(_ linear: Double) -> Double {
        let x = max(0, min(1, linear))
        if x <= 0 { return acesccMinCodeValue }
        if x < acesccLinearSegmentUpperBound {
            return (log2(pow(2, -16) + x * 0.5) + acesccLogOffset) / acesccLogScale
        }
        return (log2(x) + acesccLogOffset) / acesccLogScale
    }

    /// Decode one channel: ACEScc → linear [0,1]. Below acesccLogSegmentStart uses linear inverse; else 2^(cv*17.52 - 9.72).
    public static func acesccEOTF(_ acescc: Double) -> Double {
        let cv = max(acesccMinCodeValue, min(1, acescc))
        if cv < acesccLogSegmentStart {
            return (pow(2, cv * acesccLogScale - acesccLogOffset) - pow(2, -16)) * 2
        }
        return min(1, pow(2, cv * acesccLogScale - acesccLogOffset))
    }

    // MARK: - ACEScct OETF (scene linear → ACEScct, 0–1 normalised)

    /// Encode one channel: linear [0,1] → ACEScct. For x <= X_BRK: A*x+B; else (log2(x)+9.72)/17.52.
    public static func acescctOETF(_ linear: Double) -> Double {
        let x = max(0, min(1, linear))
        if x <= acescctXBrk {
            return acescctA * x + acescctB
        }
        return (log2(x) + acesccLogOffset) / acesccLogScale
    }

    /// Decode one channel: ACEScct → linear [0,1]. For cv > Y_BRK: 2^(cv*17.52-9.72); else (cv-B)/A.
    public static func acescctEOTF(_ acescct: Double) -> Double {
        let cv = max(0, min(1, acescct))
        if cv > acescctYBrk {
            return min(1, pow(2, cv * acesccLogScale - acesccLogOffset))
        }
        return max(0, (cv - acescctB) / acescctA)
    }
}
