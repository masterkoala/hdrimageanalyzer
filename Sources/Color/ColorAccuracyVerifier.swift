// INT-008: Color accuracy verification against reference test patterns.

import Foundation

/// Result of comparing computed RGB to a reference patch.
public struct ColorVerificationResult: Sendable {
    public let patchName: String
    public let maxDeltaR: Double
    public let maxDeltaG: Double
    public let maxDeltaB: Double
    public let maxDelta: Double
    public let tolerance: Double
    /// True if maxDelta <= tolerance.
    public var passed: Bool { maxDelta <= tolerance }

    public init(patchName: String, maxDeltaR: Double, maxDeltaG: Double, maxDeltaB: Double, tolerance: Double = ColorAccuracyVerifier.defaultTolerance) {
        self.patchName = patchName
        self.maxDeltaR = maxDeltaR
        self.maxDeltaG = maxDeltaG
        self.maxDeltaB = maxDeltaB
        self.maxDelta = max(maxDeltaR, maxDeltaG, maxDeltaB)
        self.tolerance = tolerance
    }
}

/// Verifies computed color values against reference test patterns (INT-008).
public enum ColorAccuracyVerifier {
    /// Default tolerance for linear RGB comparison (1e-4 allows small float variance).
    public static let defaultTolerance: Double = 1e-4

    /// Compare computed (r,g,b) to reference (r,g,b) and return a verification result.
    public static func verify(
        patchName: String,
        computedR: Double, computedG: Double, computedB: Double,
        referenceR: Double, referenceG: Double, referenceB: Double,
        tolerance: Double = defaultTolerance
    ) -> ColorVerificationResult {
        let dr = abs(computedR - referenceR)
        let dg = abs(computedG - referenceG)
        let db = abs(computedB - referenceB)
        return ColorVerificationResult(patchName: patchName, maxDeltaR: dr, maxDeltaG: dg, maxDeltaB: db, tolerance: tolerance)
    }

    /// Verify a single reference patch: convert patch YCbCr to RGB via the given converter and compare to patch expected RGB.
    /// - Parameter convert: (y, cb, cr) -> (r, g, b); typically BT709.ycbcrToRgb.
    /// - Returns: Verification result (passed if max delta <= tolerance).
    public static func verifyPatch(
        _ patch: ReferenceColorPatch,
        convert: (Double, Double, Double) -> (Double, Double, Double),
        tolerance: Double = defaultTolerance
    ) -> ColorVerificationResult {
        let (r, g, b) = convert(patch.y, patch.cb, patch.cr)
        let rClamp = min(max(r, 0), 1)
        let gClamp = min(max(g, 0), 1)
        let bClamp = min(max(b, 0), 1)
        return verify(
            patchName: patch.name,
            computedR: rClamp, computedG: gClamp, computedB: bClamp,
            referenceR: patch.expectedR, referenceG: patch.expectedG, referenceB: patch.expectedB,
            tolerance: tolerance
        )
    }

    /// Run verification over all patches; returns all results and overall pass (all within tolerance).
    public static func verifyAll(
        patches: [ReferenceColorPatch],
        convert: (Double, Double, Double) -> (Double, Double, Double),
        tolerance: Double = defaultTolerance
    ) -> (results: [ColorVerificationResult], passed: Bool) {
        let results = patches.map { verifyPatch($0, convert: convert, tolerance: tolerance) }
        let passed = results.allSatisfy { $0.passed }
        return (results, passed)
    }
}
