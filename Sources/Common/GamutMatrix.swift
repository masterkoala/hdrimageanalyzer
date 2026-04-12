import Foundation

/// CS-004 / SC-015: Rec.709 → target gamut 3×3 matrices (column-major, 9 floats).
/// Used for False Color Gamut Warning overlay and gamut violation checks.
/// Source is assumed Rec.709 (e.g. v210 convert output); target is Analysis Space.
public enum GamutMatrix {
    /// Rec.709 (BT.709) RGB → XYZ, D65. Column-major.
    public static let rec709ToXYZ: [Float] = [
        0.4124564, 0.2126729, 0.0193339,
        0.3575761, 0.7151522, 0.1191920,
        0.1804375, 0.0721750, 0.9503041
    ]
    /// Rec.2020 (BT.2020) RGB → XYZ, D65. Column-major.
    public static let rec2020ToXYZ: [Float] = [
        0.6369581, 0.2627002, 0.0000000,
        0.1446169, 0.6779981, 0.0280727,
        0.1688809, 0.0570571, 1.0609851
    ]
    /// DCI-P3 (Display P3) RGB → XYZ, D65. Column-major.
    public static let dciP3ToXYZ: [Float] = [
        0.4865709, 0.2289746, 0.0000000,
        0.2656677, 0.6917385, 0.0451134,
        0.1982173, 0.0792869, 1.0439443
    ]
    /// Identity (XYZ pass-through). Column-major.
    public static let identity: [Float] = [
        1, 0, 0,
        0, 1, 0,
        0, 0, 1
    ]

    /// Returns 9 floats (column-major): Rec.709 linear RGB → target gamut linear RGB.
    /// Used by SC-015 False Color Gamut Warning and QC-002–style checks when source is Rec.709.
    public static func rec709ToTarget(_ target: GamutSpace) -> [Float] {
        switch target {
        case .rec709: return identity
        case .xyz: return rec709ToXYZ
        case .rec2020: return multiply3x3(inverse3x3(rec2020ToXYZ), rec709ToXYZ)
        case .dciP3: return multiply3x3(inverse3x3(dciP3ToXYZ), rec709ToXYZ)
        }
    }

    /// Column-major 3×3 inverse. Returns identity if singular.
    private static func inverse3x3(_ m: [Float]) -> [Float] {
        guard m.count >= 9 else { return identity }
        let d = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
        guard abs(d) > 1e-10 else { return identity }
        let id = 1.0 / d
        return [
            (m[4] * m[8] - m[5] * m[7]) * id, (m[2] * m[7] - m[1] * m[8]) * id, (m[1] * m[5] - m[2] * m[4]) * id,
            (m[5] * m[6] - m[3] * m[8]) * id, (m[0] * m[8] - m[2] * m[6]) * id, (m[2] * m[3] - m[0] * m[5]) * id,
            (m[3] * m[7] - m[4] * m[6]) * id, (m[1] * m[6] - m[0] * m[7]) * id, (m[0] * m[4] - m[1] * m[3]) * id
        ]
    }

    /// Column-major 3×3 multiply: C = A * B (so that (A*B)*v = A*(B*v)).
    private static func multiply3x3(_ a: [Float], _ b: [Float]) -> [Float] {
        guard a.count >= 9, b.count >= 9 else { return identity }
        return [
            a[0] * b[0] + a[3] * b[1] + a[6] * b[2],
            a[1] * b[0] + a[4] * b[1] + a[7] * b[2],
            a[2] * b[0] + a[5] * b[1] + a[8] * b[2],
            a[0] * b[3] + a[3] * b[4] + a[6] * b[5],
            a[1] * b[3] + a[4] * b[4] + a[7] * b[5],
            a[2] * b[3] + a[5] * b[4] + a[8] * b[5],
            a[0] * b[6] + a[3] * b[7] + a[6] * b[8],
            a[1] * b[6] + a[4] * b[7] + a[7] * b[8],
            a[2] * b[6] + a[5] * b[7] + a[8] * b[8]
        ]
    }
}
