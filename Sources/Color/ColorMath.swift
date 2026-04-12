import Foundation
import Common

// MARK: - BT.709 YCbCr ↔ RGB (for Metal MT-007 and CPU reference)

/// BT.709 / Rec.709 coefficients for YCbCr → RGB conversion.
/// Use these same values in Metal shaders (MT-007) for consistency.
///
/// **Formulas** (YCbCr normalized to [0,1], neutral at 0.5):
/// - R = Y + Kr * (Cr - 0.5)
/// - G = Y - KgCb * (Cb - 0.5) - KgCr * (Cr - 0.5)
/// - B = Y + Kb * (Cb - 0.5)
///
/// BT.709 luma: Y = 0.2126*R + 0.7152*G + 0.0722*B → inverse gives the factors below.
public enum BT709 {
    /// Cr coefficient: R = Y + Kr * (Cr - 0.5)
    public static let kr: Double = 1.5748
    /// Cb coefficient for G: G = Y - KgCb*(Cb - 0.5) - KgCr*(Cr - 0.5)
    public static let kgCb: Double = 0.1873
    /// Cr coefficient for G
    public static let kgCr: Double = 0.4681
    /// Cb coefficient: B = Y + Kb * (Cb - 0.5)
    public static let kb: Double = 1.8556

    /// Neutral chroma (0.5 in normalized [0,1])
    public static let chromaNeutral: Double = 0.5

    // MARK: - Metal (MT-007) — use same coefficients in shader or pass via buffer

    /// Float coefficients for Metal YCbCr→RGB kernel (MT-007). Copy into uniform buffer or hardcode in .metal.
    public static let metalKr: Float = Float(kr)
    public static let metalKgCb: Float = Float(kgCb)
    public static let metalKgCr: Float = Float(kgCr)
    public static let metalKb: Float = Float(kb)
    public static let metalChromaNeutral: Float = Float(chromaNeutral)

    /// Convert normalized YCbCr [0,1] to linear RGB [0,1] (BT.709).
    /// Inputs are typically 10-bit scaled: Y in 64–940, Cb/Cr in 64–960 (limited range);
    /// normalize to [0,1] before calling, or use the overload that takes 10-bit values.
    public static func ycbcrToRgb(y: Double, cb: Double, cr: Double) -> (r: Double, g: Double, b: Double) {
        let crN = cr - chromaNeutral
        let cbN = cb - chromaNeutral
        let r = y + kr * crN
        let g = y - kgCb * cbN - kgCr * crN
        let b = y + kb * cbN
        return (r, g, b)
    }

    /// Convert 10-bit YCbCr (limited range: Y 64–940, Cb/Cr 64–960) to RGB [0,1].
    /// Optional: set `useFullRange` if Y/Cb/Cr are in 0–1023.
    public static func ycbcr10ToRgb(
        y10: Int, cb10: Int, cr10: Int,
        limitedRange: Bool = true
    ) -> (r: Double, g: Double, b: Double) {
        let (yNorm, cbNorm, crNorm) = normalizeYCbCr10(y: y10, cb: cb10, cr: cr10, limitedRange: limitedRange)
        return ycbcrToRgb(y: yNorm, cb: cbNorm, cr: crNorm)
    }

    /// Normalize 10-bit YCbCr to [0,1]. Limited: Y 64–940 → [0,1], Cb/Cr 64–960 → [0,1].
    public static func normalizeYCbCr10(
        y: Int, cb: Int, cr: Int,
        limitedRange: Bool = true
    ) -> (y: Double, cb: Double, cr: Double) {
        if limitedRange {
            let yNorm = (Double(y) - 64) / (940 - 64)
            let cbNorm = (Double(cb) - 64) / (960 - 64)  // 896 range
            let crNorm = (Double(cr) - 64) / (960 - 64)
            return (yNorm, cbNorm, crNorm)
        } else {
            return (Double(y) / 1023, Double(cb) / 1023, Double(cr) / 1023)
        }
    }
}

// MARK: - Rec.709 gamma (BT.1886) — CS-003

/// Rec.709 / BT.1886 transfer: gamma 2.4. Linear ↔ gamma-encoded for display.
/// Metal kernels: `rec709_linear_to_gamma`, `rec709_gamma_to_linear` (Shaders/Common/Placeholder.metal).
public enum Rec709Gamma {
    /// BT.1886 gamma (display). Linear → encoded: V' = linear^(1/γ). Encoded → linear: L = V'^γ.
    public static let gamma: Double = 2.4
    /// 1/γ for linear → gamma encoding.
    public static let gammaInv: Double = 1.0 / 2.4

    /// Float for Metal (CS-003 kernels use constants; these match for CPU/reference).
    public static let metalGamma: Float = 2.4
    public static let metalGammaInv: Float = Float(1.0 / 2.4)

    /// Linear [0,1] → Rec.709 gamma-encoded [0,1]. V' = linear^(1/2.4).
    public static func linearToGamma(_ linear: Double) -> Double {
        pow(max(0, linear), gammaInv)
    }

    /// Rec.709 gamma-encoded [0,1] → linear [0,1]. L = V'^2.4.
    public static func gammaToLinear(_ encoded: Double) -> Double {
        pow(max(0, encoded), gamma)
    }
}

// MARK: - v210 unpacking (CPU reference for MT-007)

/// v210 packed 4:2:2 10-bit YCbCr (SMPTE 296M / QuickTime).
/// Layout: 4 × 32-bit little-endian words = 6 pixels. Each word: 3 × 10-bit components, bits 0–9, 10–19, 20–29; bits 30–31 padding.
///
/// Block layout (MultimediaWiki):
/// - Block 1: Cb0 (bits 20–29), Y0 (10–19), Cr0 (0–9)
/// - Block 2: Y1 (0–9), Cb1 (10–19), Y2 (20–29)
/// - Block 3: Cr1 (0–9), Y3 (10–19), Cb2 (20–29)
/// - Block 4: Y4 (0–9), Cr2 (10–19), Y5 (20–29)
///
/// Pixels: (Y0,Cb0,Cr0), (Y1,Cb0,Cr0), (Y2,Cb1,Cr1), (Y3,Cb1,Cr1), (Y4,Cb2,Cr2), (Y5,Cb2,Cr2).
public enum V210 {
    /// Number of 32-bit words per 6 pixels (one v210 "macroblock").
    public static let wordsPerMacroblock = 4
    /// Pixels per macroblock.
    public static let pixelsPerMacroblock = 6
    /// Bytes per macroblock.
    public static let bytesPerMacroblock = 16

    /// Stride for a row: width must be multiple of 6; row bytes = (width / 6) * 16.
    /// Lines are often aligned to 128 bytes (zero-padded).
    public static func rowBytes(width: Int) -> Int {
        let macroblocks = (width + pixelsPerMacroblock - 1) / pixelsPerMacroblock
        return macroblocks * bytesPerMacroblock
    }

    /// Unpack one macroblock (4 words) into 6 pixels of 10-bit Y, Cb, Cr.
    /// `words` must have at least 4 elements. Returns arrays of 6 elements each.
    public static func unpackMacroblock(_ words: [UInt32]) -> (y: [UInt16], cb: [UInt16], cr: [UInt16]) {
        precondition(words.count >= 4)
        let w0 = words[0], w1 = words[1], w2 = words[2], w3 = words[3]
        let mask = 0x3FF as UInt32
        let y = [
            UInt16((w0 >> 10) & mask),
            UInt16(w1 & mask),
            UInt16((w1 >> 20) & mask),
            UInt16((w2 >> 10) & mask),
            UInt16(w3 & mask),
            UInt16((w3 >> 20) & mask)
        ]
        let cb = [
            UInt16((w0 >> 20) & mask),
            UInt16((w0 >> 20) & mask),
            UInt16((w1 >> 10) & mask),
            UInt16((w1 >> 10) & mask),
            UInt16((w2 >> 20) & mask),
            UInt16((w2 >> 20) & mask)
        ]
        let cr = [
            UInt16(w0 & mask),
            UInt16(w0 & mask),
            UInt16(w2 & mask),
            UInt16(w2 & mask),
            UInt16((w3 >> 10) & mask),
            UInt16((w3 >> 10) & mask)
        ]
        return (y, cb, cr)
    }

    /// Unpack v210 buffer to 10-bit Y, Cb, Cr arrays (one value per pixel; Cb/Cr subsampled 4:2:2).
    /// Buffer length must be at least `rowBytes(width) * height`. Output arrays have `width * height` elements.
    public static func unpack(
        buffer: UnsafeRawBufferPointer,
        width: Int,
        height: Int
    ) -> (y: [UInt16], cb: [UInt16], cr: [UInt16])? {
        let rowStride = rowBytes(width: width)
        let totalBytes = rowStride * height
        guard buffer.count >= totalBytes else { return nil }
        let wordsPerRow = rowStride / 4
        let words = buffer.bindMemory(to: UInt32.self)
        var yOut = [UInt16](repeating: 0, count: width * height)
        var cbOut = [UInt16](repeating: 0, count: width * height)
        var crOut = [UInt16](repeating: 0, count: width * height)
        for row in 0..<height {
            let rowWordBase = row * wordsPerRow
            var col = 0
            while col < width {
                let mbCol = col / pixelsPerMacroblock
                let wordBase = rowWordBase + mbCol * wordsPerMacroblock
                guard wordBase + 4 <= buffer.count / 4 else { break }
                let block = [words[wordBase], words[wordBase + 1], words[wordBase + 2], words[wordBase + 3]]
                let (y, cb, cr) = unpackMacroblock(block)
                for i in 0..<pixelsPerMacroblock where (col + i) < width {
                    let idx = row * width + col + i
                    yOut[idx] = y[i]
                    cbOut[idx] = cb[i]
                    crOut[idx] = cr[i]
                }
                col += pixelsPerMacroblock
            }
        }
        return (yOut, cbOut, crOut)
    }

    /// Unpack a single pixel from v210 buffer at (x, y). Uses 4:2:2 chroma sharing.
    public static func unpackPixel(
        buffer: UnsafeRawBufferPointer,
        width: Int,
        height: Int,
        x: Int,
        y: Int
    ) -> (y: UInt16, cb: UInt16, cr: UInt16)? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let rowStride = rowBytes(width: width)
        let macroblockX = x / pixelsPerMacroblock
        let offsetInBlock = x % pixelsPerMacroblock
        let wordOffset = (y * (rowStride / 4)) + (macroblockX * wordsPerMacroblock)
        guard (wordOffset + 4) * 4 <= buffer.count else { return nil }
        let words = buffer.bindMemory(to: UInt32.self)
        let (yArr, cbArr, crArr) = unpackMacroblock(Array(words[wordOffset..<(wordOffset + 4)]))
        return (yArr[offsetInBlock], cbArr[offsetInBlock], crArr[offsetInBlock])
    }
}
