// INT-008: Reference test patterns for color accuracy verification.
// SMPTE / Rec.709 style patches: normalized YCbCr [0,1] and expected linear RGB [0,1] (BT.709).

import Foundation

/// A single reference patch: normalized YCbCr and expected linear RGB (BT.709).
public struct ReferenceColorPatch: Sendable {
    public let name: String
    public let y: Double
    public let cb: Double
    public let cr: Double
    /// Expected linear RGB [0,1] from BT.709 YCbCr→RGB.
    public let expectedR: Double
    public let expectedG: Double
    public let expectedB: Double

    public init(name: String, y: Double, cb: Double, cr: Double, expectedR: Double, expectedG: Double, expectedB: Double) {
        self.name = name
        self.y = y
        self.cb = cb
        self.cr = cr
        self.expectedR = expectedR
        self.expectedG = expectedG
        self.expectedB = expectedB
    }
}

/// Standard reference test patterns for color accuracy verification (INT-008).
/// Values are normalized YCbCr [0,1] (limited-range mapping) and expected linear RGB from BT.709.
public enum ReferenceTestPatterns {
    /// Grayscale ramp (0%, 25%, 50%, 75%, 100%) — neutral Cb=Cr=0.5.
    public static let grayscaleRamp: [ReferenceColorPatch] = [
        ReferenceColorPatch(name: "Black",       y: 0.0,   cb: 0.5, cr: 0.5, expectedR: 0.0,   expectedG: 0.0,   expectedB: 0.0),
        ReferenceColorPatch(name: "25% Grey",   y: 0.25,  cb: 0.5, cr: 0.5, expectedR: 0.25,  expectedG: 0.25,  expectedB: 0.25),
        ReferenceColorPatch(name: "50% Grey",   y: 0.5,   cb: 0.5, cr: 0.5, expectedR: 0.5,   expectedG: 0.5,   expectedB: 0.5),
        ReferenceColorPatch(name: "75% Grey",   y: 0.75,  cb: 0.5, cr: 0.5, expectedR: 0.75,  expectedG: 0.75,  expectedB: 0.75),
        ReferenceColorPatch(name: "100% White", y: 1.0,   cb: 0.5, cr: 0.5, expectedR: 1.0,   expectedG: 1.0,   expectedB: 1.0),
    ]

    /// Rec.709 / SMPTE-style 75% color bars (normalized YCbCr). Expected linear RGB from BT.709 YCbCr→RGB.
    /// Values match BT.709 conversion for these YCbCr inputs (clamped to [0,1]).
    public static let rec709ColorBars: [ReferenceColorPatch] = [
        ReferenceColorPatch(name: "White",   y: 1.0,   cb: 0.5,   cr: 0.5,   expectedR: 1.0,   expectedG: 1.0,   expectedB: 1.0),
        ReferenceColorPatch(name: "Yellow",  y: 0.676, cb: 0.122, cr: 0.750, expectedR: 1.0,   expectedG: 0.630, expectedB: 0.0),
        ReferenceColorPatch(name: "Cyan",    y: 0.591, cb: 0.579, cr: 0.122, expectedR: 0.0,   expectedG: 0.782, expectedB: 0.738),
        ReferenceColorPatch(name: "Green",   y: 0.523, cb: 0.122, cr: 0.122, expectedR: 0.0,   expectedG: 0.771, expectedB: 0.0),
        ReferenceColorPatch(name: "Magenta", y: 0.402, cb: 0.579, cr: 0.579, expectedR: 0.526, expectedG: 0.35,  expectedB: 0.549),
        ReferenceColorPatch(name: "Red",     y: 0.313, cb: 0.579, cr: 0.579, expectedR: 0.437, expectedG: 0.276, expectedB: 0.46),
        ReferenceColorPatch(name: "Blue",    y: 0.169, cb: 0.579, cr: 0.122, expectedR: 0.0,   expectedG: 0.361, expectedB: 0.316),
        ReferenceColorPatch(name: "Black",   y: 0.0,   cb: 0.5,   cr: 0.5,   expectedR: 0.0,   expectedG: 0.0,   expectedB: 0.0),
    ]

    /// Unique set: grayscale ramp + color bar primaries/secondaries (no duplicate White/Black).
    public static var verificationPatches: [ReferenceColorPatch] {
        var seen = Set<String>()
        var out: [ReferenceColorPatch] = []
        for p in grayscaleRamp + rec709ColorBars {
            if seen.insert(p.name).inserted { out.append(p) }
        }
        return out
    }
}
