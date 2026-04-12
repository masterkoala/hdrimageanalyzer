import XCTest
import CoreGraphics
import ImageIO
@testable import Color

final class ColorTests: XCTestCase {
    func testColorModuleLoads() {
        XCTAssertTrue(true)
    }

    /// BT.709 YCbCr → RGB: neutral (0.5, 0.5, 0.5) → grey; one 10-bit triple → expected RGB.
    func testBT709YCbCrToRgb() {
        let (r, g, b) = BT709.ycbcrToRgb(y: 0.5, cb: 0.5, cr: 0.5)
        XCTAssertEqual(r, 0.5, accuracy: 1e-5)
        XCTAssertEqual(g, 0.5, accuracy: 1e-5)
        XCTAssertEqual(b, 0.5, accuracy: 1e-5)

        // 10-bit limited: Y=512 (mid), Cb=512, Cr=512 → normalize to ~0.5 → grey
        let (r2, g2, b2) = BT709.ycbcr10ToRgb(y10: 512, cb10: 512, cr10: 512, limitedRange: true)
        XCTAssertEqual(r2, 0.5, accuracy: 0.02)
        XCTAssertEqual(g2, 0.5, accuracy: 0.02)
        XCTAssertEqual(b2, 0.5, accuracy: 0.02)
    }

    /// v210: unpack one macroblock (4 words) into 6 pixels; first pixel YCbCr → RGB.
    func testV210UnpackAndConvert() {
        // One macroblock: Cb0 Y0 Cr0 | Y1 Cb1 Y2 | Cr1 Y3 Cb2 | Y4 Cr2 Y5 (10-bit each, LE)
        // Build so Y0=512, Cb0=512, Cr0=512 (neutral grey).
        let y0 = 512 as UInt32, cb0 = 512 as UInt32, cr0 = 512 as UInt32
        let y1 = 512 as UInt32, cb1 = 512 as UInt32, y2 = 512 as UInt32
        let cr1 = 512 as UInt32, y3 = 512 as UInt32, cb2 = 512 as UInt32
        let y4 = 512 as UInt32, cr2 = 512 as UInt32, y5 = 512 as UInt32
        let w0 = (cb0 << 20) | (y0 << 10) | cr0
        let w1 = (y2 << 20) | (cb1 << 10) | y1
        let w2 = (cb2 << 20) | (y3 << 10) | cr1
        let w3 = (y5 << 20) | (cr2 << 10) | y4
        let (y, cb, cr) = V210.unpackMacroblock([w0, w1, w2, w3])
        XCTAssertEqual(y[0], 512)
        XCTAssertEqual(cb[0], 512)
        XCTAssertEqual(cr[0], 512)
        let (r, g, b) = BT709.ycbcr10ToRgb(y10: Int(y[0]), cb10: Int(cb[0]), cr10: Int(cr[0]), limitedRange: true)
        XCTAssertEqual(r, 0.5, accuracy: 0.02)
        XCTAssertEqual(g, 0.5, accuracy: 0.02)
        XCTAssertEqual(b, 0.5, accuracy: 0.02)
    }

    // MARK: - INT-008 Color accuracy verification against reference test patterns

    func testColorAccuracyVerification_GrayscaleRamp() {
        let convert: (Double, Double, Double) -> (Double, Double, Double) = { BT709.ycbcrToRgb(y: $0, cb: $1, cr: $2) }
        let (results, passed) = ColorAccuracyVerifier.verifyAll(
            patches: ReferenceTestPatterns.grayscaleRamp,
            convert: convert,
            tolerance: 1e-5
        )
        XCTAssertTrue(passed, "Grayscale ramp verification failed: \(results.filter { !$0.passed }.map { "\($0.patchName) Δ=\($0.maxDelta)" })")
    }

    func testColorAccuracyVerification_Rec709ColorBars() {
        let convert: (Double, Double, Double) -> (Double, Double, Double) = { BT709.ycbcrToRgb(y: $0, cb: $1, cr: $2) }
        // Tolerance 0.04: reference patches use approximate expected values; BT.709 conversion verified within 4%.
        let (results, passed) = ColorAccuracyVerifier.verifyAll(
            patches: ReferenceTestPatterns.rec709ColorBars,
            convert: convert,
            tolerance: 0.04
        )
        XCTAssertTrue(passed, "Rec.709 color bars verification failed: \(results.filter { !$0.passed }.map { "\($0.patchName) Δ=\($0.maxDelta)" })")
    }

    func testColorAccuracyVerification_AllVerificationPatches() {
        let convert: (Double, Double, Double) -> (Double, Double, Double) = { BT709.ycbcrToRgb(y: $0, cb: $1, cr: $2) }
        // Tolerance 0.04: color bar primaries use approximate expected values; grayscale exact.
        let (results, passed) = ColorAccuracyVerifier.verifyAll(
            patches: ReferenceTestPatterns.verificationPatches,
            convert: convert,
            tolerance: 0.04
        )
        XCTAssertTrue(passed, "Full verification failed: \(results.filter { !$0.passed }.map { "\($0.patchName) Δ=\($0.maxDelta)" })")
    }

    func testColorAccuracyVerification_10BitLimitedRoundTrip() {
        // 10-bit limited range: key values 64, 512, 940 (Y) and 64, 512, 960 (Cb/Cr).
        let patches: [(name: String, y10: Int, cb10: Int, cr10: Int)] = [
            ("Black", 64, 512, 512),
            ("50% Grey", 512, 512, 512),
            ("100% White", 940, 512, 512),
        ]
        for p in patches {
            let (r, g, b) = BT709.ycbcr10ToRgb(y10: p.y10, cb10: p.cb10, cr10: p.cr10, limitedRange: true)
            let (yN, cbN, crN) = BT709.normalizeYCbCr10(y: p.y10, cb: p.cb10, cr: p.cr10, limitedRange: true)
            let (r2, g2, b2) = BT709.ycbcrToRgb(y: yN, cb: cbN, cr: crN)
            XCTAssertEqual(r, r2, accuracy: 1e-5, "\(p.name) R")
            XCTAssertEqual(g, g2, accuracy: 1e-5, "\(p.name) G")
            XCTAssertEqual(b, b2, accuracy: 1e-5, "\(p.name) B")
        }
    }

    // MARK: - CS-017 Color accuracy unit tests (known reference values)

    /// BT.709 YCbCr→RGB coefficients (ITU-R BT.709 / MT-007). Inverse matrix constants.
    func testBT709CoefficientsReferenceValues() {
        // Reference: BT.709 inverse transform R = Y + Kr*(Cr-0.5), etc. Kr≈1.5748, Kb≈1.8556.
        let refKr: Double = 1.5748
        let refKgCb: Double = 0.1873
        let refKgCr: Double = 0.4681
        let refKb: Double = 1.8556
        XCTAssertEqual(BT709.kr, refKr, accuracy: 1e-4)
        XCTAssertEqual(BT709.kgCb, refKgCb, accuracy: 1e-4)
        XCTAssertEqual(BT709.kgCr, refKgCr, accuracy: 1e-4)
        XCTAssertEqual(BT709.kb, refKb, accuracy: 1e-4)
        XCTAssertEqual(BT709.chromaNeutral, 0.5, accuracy: 1e-10)
    }

    /// Rec.709 / BT.1886 gamma: constant 2.4 and round-trip consistency (reference from implementation).
    func testRec709GammaReferenceValues() {
        // BT.1886 specifies γ = 2.4; verify constant.
        XCTAssertEqual(Rec709Gamma.gamma, 2.4, accuracy: 1e-10)
        XCTAssertEqual(Rec709Gamma.gammaInv, 1.0 / 2.4, accuracy: 1e-10)

        // Reference from implementation: linear 0.5 → encoded must round-trip.
        let linearMid: Double = 0.5
        let encodedMid = Rec709Gamma.linearToGamma(linearMid)
        let linearBack = Rec709Gamma.gammaToLinear(encodedMid)
        XCTAssertEqual(linearBack, linearMid, accuracy: 1e-9)

        // Encoded 0.5 → linear must round-trip.
        let encodedHalf: Double = 0.5
        let linearFromEncoded = Rec709Gamma.gammaToLinear(encodedHalf)
        let encodedBack = Rec709Gamma.linearToGamma(linearFromEncoded)
        XCTAssertEqual(encodedBack, encodedHalf, accuracy: 1e-9)

        // Boundaries
        XCTAssertEqual(Rec709Gamma.linearToGamma(0), 0, accuracy: 1e-10)
        XCTAssertEqual(Rec709Gamma.linearToGamma(1), 1, accuracy: 1e-10)
        XCTAssertEqual(Rec709Gamma.gammaToLinear(0), 0, accuracy: 1e-10)
        XCTAssertEqual(Rec709Gamma.gammaToLinear(1), 1, accuracy: 1e-10)
    }

    /// 10-bit limited range normalization: exact reference mapping (Y 64–940, Cb/Cr 64–960).
    func testNormalizeYCbCr10LimitedRangeReferenceValues() {
        // Y: 64→0, 940→1 → (512-64)/(940-64) = 448/876
        let (yMid, cbMid, crMid) = BT709.normalizeYCbCr10(y: 512, cb: 512, cr: 512, limitedRange: true)
        let refY: Double = (512 - 64) / (940 - 64)  // 448/876
        let refCb: Double = (512 - 64) / (960 - 64) // 448/896
        XCTAssertEqual(yMid, refY, accuracy: 1e-10)
        XCTAssertEqual(cbMid, refCb, accuracy: 1e-10)
        XCTAssertEqual(crMid, refCb, accuracy: 1e-10)

        // Black: 64,64,64 → 0, 0.5, 0.5 (Cb/Cr neutral at 64 → (64-64)/896 = 0, but 512 is mid 0.5; 64 in 64–960 → 0)
        let (yB, cbB, crB) = BT709.normalizeYCbCr10(y: 64, cb: 512, cr: 512, limitedRange: true)
        XCTAssertEqual(yB, 0, accuracy: 1e-10)
        XCTAssertEqual(cbB, (512 - 64) / 896, accuracy: 1e-10)
        XCTAssertEqual(crB, (512 - 64) / 896, accuracy: 1e-10)

        // White Y: 940 → 1
        let (yW, _, _) = BT709.normalizeYCbCr10(y: 940, cb: 512, cr: 512, limitedRange: true)
        XCTAssertEqual(yW, 1, accuracy: 1e-10)
    }

    /// YCbCr→RGB: SMPTE-style reference (neutral grey and primaries). Known reference RGB for given YCbCr.
    func testBT709YCbCrToRgbKnownReferenceValues() {
        // Neutral (0.5, 0.5, 0.5) → (0.5, 0.5, 0.5)
        let (r0, g0, b0) = BT709.ycbcrToRgb(y: 0.5, cb: 0.5, cr: 0.5)
        XCTAssertEqual(r0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(g0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(b0, 0.5, accuracy: 1e-9)

        // Black (0, 0.5, 0.5)
        let (r1, g1, b1) = BT709.ycbcrToRgb(y: 0, cb: 0.5, cr: 0.5)
        XCTAssertEqual(r1, 0, accuracy: 1e-9)
        XCTAssertEqual(g1, 0, accuracy: 1e-9)
        XCTAssertEqual(b1, 0, accuracy: 1e-9)

        // White (1, 0.5, 0.5)
        let (r2, g2, b2) = BT709.ycbcrToRgb(y: 1, cb: 0.5, cr: 0.5)
        XCTAssertEqual(r2, 1, accuracy: 1e-9)
        XCTAssertEqual(g2, 1, accuracy: 1e-9)
        XCTAssertEqual(b2, 1, accuracy: 1e-9)

        // Rec.709 color bar patch (0.313, 0.579, 0.579): output in [0,1].
        let (rBar, gBar, bBar) = BT709.ycbcrToRgb(y: 0.313, cb: 0.579, cr: 0.579)
        XCTAssertGreaterThanOrEqual(rBar, 0); XCTAssertLessThanOrEqual(rBar, 1)
        XCTAssertGreaterThanOrEqual(gBar, 0); XCTAssertLessThanOrEqual(gBar, 1)
        XCTAssertGreaterThanOrEqual(bBar, 0); XCTAssertLessThanOrEqual(bBar, 1)
    }

    /// ColorAccuracyVerifier: single patch against explicit reference numbers.
    func testColorAccuracyVerifierAgainstExplicitReference() {
        let result = ColorAccuracyVerifier.verify(
            patchName: "Grey50",
            computedR: 0.5, computedG: 0.5, computedB: 0.5,
            referenceR: 0.5, referenceG: 0.5, referenceB: 0.5,
            tolerance: 1e-5
        )
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.maxDelta, 0, accuracy: 1e-10)

        let result2 = ColorAccuracyVerifier.verify(
            patchName: "OffByTolerance",
            computedR: 0.5 + 5e-5, computedG: 0.5, computedB: 0.5,
            referenceR: 0.5, referenceG: 0.5, referenceB: 0.5,
            tolerance: 1e-4
        )
        XCTAssertTrue(result2.passed)
        XCTAssertEqual(result2.maxDeltaR, 5e-5, accuracy: 1e-10)
    }

    // MARK: - CS-018 Comprehensive color transform test images (bundled resources)

    /// All CS-018 test image filenames (without extension). Regenerate with Scripts/generate_color_test_images.py.
    private static let colorTransformTestImageNames = [
        "grayscale_ramp", "rec709_color_bars", "black", "neutral_grey", "white",
        "red_709", "green_709", "blue_709", "verification_grid", "linear_ramp_11",
    ]

    /// CS-018: Verify all comprehensive color transform test images are present in the test bundle.
    func testColorTransformTestImagesBundled() {
        for name in Self.colorTransformTestImageNames {
            let url = Bundle.module.url(forResource: name, withExtension: "png")
            XCTAssertNotNil(url, "CS-018 test image '\(name).png' should be in Tests/ColorTests/Resources")
        }
    }

    /// CS-018: Verify neutral_grey test image has expected dimensions (16×16).
    func testColorTransformTestImageNeutralGreyDimensions() throws {
        guard let url = Bundle.module.url(forResource: "neutral_grey", withExtension: "png") else {
            throw XCTSkip("neutral_grey.png not found — run Scripts/generate_color_test_images.py")
        }
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("Could not decode neutral_grey.png as CGImage")
            return
        }
        XCTAssertEqual(image.width, 16, "neutral_grey.png width")
        XCTAssertEqual(image.height, 16, "neutral_grey.png height")
    }
}
