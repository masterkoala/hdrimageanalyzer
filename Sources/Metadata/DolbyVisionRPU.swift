// DolbyVisionRPU.swift
// Parse Dolby Vision RPU (SMPTE ST 2094-10) from VANC payloads (DV-001).
// Extract RPU from DID/SDID; decode base structure (rpu_header). Output for DV-004+.
// Reference: quietvoid/dovi_tool, FFmpeg libavcodec/dovi_rpu.h, libavutil/dovi_meta.h

import Foundation
import Logging
import Common
import Capture

// MARK: - RPU format version (CMv2.9 vs CMv4.0, DV-008)

/// Dolby Vision RPU content mapping version derived from rpu_format (10-bit).
/// CMv2.9: L2 trim controls, legacy mapping. CMv4.0: L8 trim improvements, extended header optional.
public enum DolbyVisionRPUFormatVersion: Sendable {
    /// Content mapping version 2.9 (rpu_format 0, 1, or 2).
    case cmv2_9
    /// Content mapping version 4.0 (rpu_format 4).
    case cmv4_0
    /// Other / reserved rpu_format value (e.g. 3, 5–1023).
    case other(UInt16)
    /// Header not parsed; rpu_format unknown.
    case unknown

    /// Classify from RPU NAL rpu_format (10-bit).
    public static func from(rpuFormat: UInt16) -> DolbyVisionRPUFormatVersion {
        switch rpuFormat {
        case 0, 1, 2: return .cmv2_9
        case 4: return .cmv4_0
        default: return .other(rpuFormat)
        }
    }

    /// Human-readable label for UI/QC.
    public var displayName: String {
        switch self {
        case .cmv2_9: return "CMv2.9"
        case .cmv4_0: return "CMv4.0"
        case .other(let v): return "CMv(\(v))"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - RPU header (base structure, SMPTE ST 2094-10)

/// Dolby Vision RPU data header (base structure only; full parsing in DV-004+).
/// Mirrors key fields from AVDOVIRpuDataHeader for display and downstream use.
public struct DolbyVisionRPUHeader: Sendable {
    /// RPU type (e.g. 0 = single layer, 1 = dual layer).
    public let rpuType: UInt8
    /// RPU format / structure version.
    public let rpuFormat: UInt16
    /// VDR RPU profile (0 = profile 5–like, 1 = profile 7/8–like).
    public let vdrRpuProfile: UInt8
    /// VDR RPU level.
    public let vdrRpuLevel: UInt8
    /// Chroma resampling explicit filter flag.
    public let chromaResamplingExplicitFilterFlag: Bool
    /// Coefficient data type (informative).
    public let coefDataType: UInt8
    /// Coefficient log2 denominator.
    public let coefLog2Denom: UInt8
    /// VDR RPU normalized IDC.
    public let vdrRpuNormalizedIdc: UInt8
    /// Base layer video full range flag.
    public let blVideoFullRangeFlag: Bool
    /// Base layer bit depth [8, 16].
    public let blBitDepth: UInt8
    /// Enhancement layer bit depth [8, 16].
    public let elBitDepth: UInt8
    /// VDR bit depth [8, 16].
    public let vdrBitDepth: UInt8
    /// Spatial resampling filter flag.
    public let spatialResamplingFilterFlag: Bool
    /// EL spatial resampling filter flag.
    public let elSpatialResamplingFilterFlag: Bool
    /// Disable residual flag.
    public let disableResidualFlag: Bool

    /// Content mapping version (CMv2.9 / CMv4.0) from rpu_format for display and format-aware parsing.
    public var formatVersion: DolbyVisionRPUFormatVersion {
        DolbyVisionRPUFormatVersion.from(rpuFormat: rpuFormat)
    }

    public init(
        rpuType: UInt8,
        rpuFormat: UInt16,
        vdrRpuProfile: UInt8,
        vdrRpuLevel: UInt8,
        chromaResamplingExplicitFilterFlag: Bool,
        coefDataType: UInt8,
        coefLog2Denom: UInt8,
        vdrRpuNormalizedIdc: UInt8,
        blVideoFullRangeFlag: Bool,
        blBitDepth: UInt8,
        elBitDepth: UInt8,
        vdrBitDepth: UInt8,
        spatialResamplingFilterFlag: Bool,
        elSpatialResamplingFilterFlag: Bool,
        disableResidualFlag: Bool
    ) {
        self.rpuType = rpuType
        self.rpuFormat = rpuFormat
        self.vdrRpuProfile = vdrRpuProfile
        self.vdrRpuLevel = vdrRpuLevel
        self.chromaResamplingExplicitFilterFlag = chromaResamplingExplicitFilterFlag
        self.coefDataType = coefDataType
        self.coefLog2Denom = coefLog2Denom
        self.vdrRpuNormalizedIdc = vdrRpuNormalizedIdc
        self.blVideoFullRangeFlag = blVideoFullRangeFlag
        self.blBitDepth = blBitDepth
        self.elBitDepth = elBitDepth
        self.vdrBitDepth = vdrBitDepth
        self.spatialResamplingFilterFlag = spatialResamplingFilterFlag
        self.elSpatialResamplingFilterFlag = elSpatialResamplingFilterFlag
        self.disableResidualFlag = disableResidualFlag
    }
}

// MARK: - Level 1 metadata (DV-004)

/// Dolby Vision Level 1 metadata: min/max/avg PQ luminance per frame (SMPTE ST 2094-10).
/// Structured type for UI display and QC. Values are PQ-encoded (12-bit range 0–4095, normalized 0.0–1.0).
public struct DolbyVisionLevel1Metadata: Sendable {

    /// Minimum PQ luminance (12-bit raw 0–4095).
    public let minPQRaw: UInt16
    /// Maximum PQ luminance (12-bit raw 0–4095).
    public let maxPQRaw: UInt16
    /// Average (mid-tone) PQ luminance (12-bit raw 0–4095).
    public let avgPQRaw: UInt16

    /// Normalized min PQ in [0, 1] for UI (PQ 4095 = 1.0).
    public var minPQNormalized: Double { minPQRaw <= 4095 ? Double(minPQRaw) / 4095.0 : 1.0 }
    /// Normalized max PQ in [0, 1] for UI.
    public var maxPQNormalized: Double { maxPQRaw <= 4095 ? Double(maxPQRaw) / 4095.0 : 1.0 }
    /// Normalized avg PQ in [0, 1] for UI.
    public var avgPQNormalized: Double { avgPQRaw <= 4095 ? Double(avgPQRaw) / 4095.0 : 1.0 }

    public init(minPQRaw: UInt16, maxPQRaw: UInt16, avgPQRaw: UInt16) {
        self.minPQRaw = min(minPQRaw, 4095)
        self.maxPQRaw = min(maxPQRaw, 4095)
        self.avgPQRaw = min(avgPQRaw, 4095)
    }
}

// MARK: - Level 2 metadata (DV-005)

/// Trim parameters for one target display (SMPTE ST 2094-10 Level 2).
/// Used for SDR/target display trim pass; slope and offset are 12-bit (0–4095).
public struct DolbyVisionLevel2TargetTrim: Sendable {
    /// Trim slope (12-bit raw 0–4095).
    public let trimSlopeRaw: UInt16
    /// Trim offset (12-bit raw 0–4095).
    public let trimOffsetRaw: UInt16

    /// Normalized slope for UI (0.0–1.0).
    public var trimSlopeNormalized: Double { trimSlopeRaw <= 4095 ? Double(trimSlopeRaw) / 4095.0 : 1.0 }
    /// Normalized offset for UI (0.0–1.0).
    public var trimOffsetNormalized: Double { trimOffsetRaw <= 4095 ? Double(trimOffsetRaw) / 4095.0 : 1.0 }

    public init(trimSlopeRaw: UInt16, trimOffsetRaw: UInt16) {
        self.trimSlopeRaw = min(trimSlopeRaw, 4095)
        self.trimOffsetRaw = min(trimOffsetRaw, 4095)
    }
}

/// Dolby Vision Level 2 metadata: trims per target display (SMPTE ST 2094-10).
/// One trim (slope, offset) per target display for tone mapping / SDR trim pass.
public struct DolbyVisionLevel2Metadata: Sendable {
    /// Trims per target display; index corresponds to target display.
    public let targetTrims: [DolbyVisionLevel2TargetTrim]

    public init(targetTrims: [DolbyVisionLevel2TargetTrim]) {
        self.targetTrims = targetTrims
    }
}

// MARK: - Level 5 metadata (DV-006)

/// Dolby Vision Level 5 metadata: active area offsets (SMPTE ST 2094-10).
/// Defines the active picture rectangle (left, right, top, bottom) in pixel units.
/// Aligned with FFmpeg AVDOVIDmLevel5.
public struct DolbyVisionLevel5Metadata: Sendable {
    /// Active area left offset (pixels).
    public let leftOffset: UInt16
    /// Active area right offset (pixels).
    public let rightOffset: UInt16
    /// Active area top offset (pixels).
    public let topOffset: UInt16
    /// Active area bottom offset (pixels).
    public let bottomOffset: UInt16

    public init(leftOffset: UInt16, rightOffset: UInt16, topOffset: UInt16, bottomOffset: UInt16) {
        self.leftOffset = leftOffset
        self.rightOffset = rightOffset
        self.topOffset = topOffset
        self.bottomOffset = bottomOffset
    }
}

// MARK: - Level 6 metadata (DV-007)

/// Dolby Vision Level 6 metadata: MaxCLL and MaxFALL (SMPTE ST 2094-10).
/// Maximum Content Light Level and Maximum Frame-Average Light Level in cd/m² (1 LSB = 1 cd/m²).
/// Same semantics as HDR10 static metadata; 0 means not specified.
public struct DolbyVisionLevel6Metadata: Sendable {
    /// Maximum content light level (cd/m²). 0 = not specified.
    public let maxCLL: UInt16
    /// Maximum frame-average light level (cd/m²). 0 = not specified.
    public let maxFALL: UInt16

    public init(maxCLL: UInt16, maxFALL: UInt16) {
        self.maxCLL = maxCLL
        self.maxFALL = maxFALL
    }

    /// Whether MaxCLL is present (non-zero).
    public var hasMaxCLL: Bool { maxCLL > 0 }
    /// Whether MaxFALL is present (non-zero).
    public var hasMaxFALL: Bool { maxFALL > 0 }
}

// MARK: - Parsed RPU (output for DV-004+)

/// Parsed Dolby Vision RPU from VANC: optional decoded header + raw payload for downstream (DV-004 display, L1–L11).
public struct DolbyVisionRPU: Sendable {
    /// Decoded base rpu_header; nil if payload too short or parse failed (raw payload still usable).
    public let header: DolbyVisionRPUHeader?
    /// Raw RPU bytes (after optional NAL prefix strip) for full decode or pass-through.
    public let rawPayload: Data
    /// VANC line number this RPU came from.
    public let lineNumber: UInt32

    public init(header: DolbyVisionRPUHeader?, rawPayload: Data, lineNumber: UInt32) {
        self.header = header
        self.rawPayload = rawPayload
        self.lineNumber = lineNumber
    }

    /// Content mapping version (CMv2.9 / CMv4.0) from parsed header; .unknown if header is nil.
    public var formatVersion: DolbyVisionRPUFormatVersion {
        header?.formatVersion ?? .unknown
    }

    /// Decoded Level 1 (min/max/avg PQ) when present; nil if not present or parse failed.
    public var level1: DolbyVisionLevel1Metadata? {
        DolbyVisionRPUParser.decodeLevel1(from: self)
    }

    /// Decoded Level 2 (trims per target display) when present; nil if not present or parse failed.
    public var level2: DolbyVisionLevel2Metadata? {
        DolbyVisionRPUParser.decodeLevel2(from: self)
    }

    /// Decoded Level 5 (active area offsets) when present; nil if not present or parse failed.
    public var level5: DolbyVisionLevel5Metadata? {
        DolbyVisionRPUParser.decodeLevel5(from: self)
    }

    /// Decoded Level 6 (MaxCLL, MaxFALL) when present; nil if not present or parse failed.
    public var level6: DolbyVisionLevel6Metadata? {
        DolbyVisionRPUParser.decodeLevel6(from: self)
    }
}

// MARK: - Bit reader for RPU

private struct BitReader {
    private let bytes: [UInt8]
    private var byteOffset: Int = 0
    private var bitOffset: Int = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var bitsRemaining: Int {
        (bytes.count - byteOffset) * 8 - bitOffset
    }

    mutating func readBits(_ n: Int) -> UInt64? {
        guard n > 0, n <= 64, bitsRemaining >= n else { return nil }
        var value: UInt64 = 0
        var left = n
        while left > 0 {
            let byte = byteOffset < bytes.count ? bytes[byteOffset] : 0
            let bitsInByte = 8 - bitOffset
            let take = min(left, bitsInByte)
            let shift = bitsInByte - take
            let mask = (1 << take) - 1
            value = (value << take) | UInt64((Int(byte) >> shift) & mask)
            bitOffset += take
            if bitOffset >= 8 {
                byteOffset += 1
                bitOffset = 0
            }
            left -= take
        }
        return value
    }

    mutating func readBit() -> Bool? {
        readBits(1).map { $0 != 0 }
    }

    /// Unsigned exponential Golomb (UE); up to 31 bits for typical RPU fields.
    mutating func readUE() -> UInt64? {
        var leadingZeros = 0
        while readBit() == false {
            leadingZeros += 1
            if leadingZeros > 31 { return nil }
        }
        guard let bits = readBits(leadingZeros) else { return nil }
        return (1 << leadingZeros) - 1 + bits
    }
}

// MARK: - NAL / payload strip

private let kNALStartCodeShort: [UInt8] = [0x00, 0x00, 0x01]
private let kNALStartCodeLong: [UInt8] = [0x00, 0x00, 0x00, 0x01]

/// Returns payload after stripping optional NAL start code, and whether a start code was present.
private func stripNALStartCodeAndDetect(_ data: Data) -> (Data, hadStartCode: Bool) {
    let bytes = [UInt8](data)
    if bytes.count >= 4 && data.subdata(in: 0..<4).elementsEqual(kNALStartCodeLong) {
        return (data.subdata(in: 4..<data.count), true)
    }
    if bytes.count >= 3 && data.subdata(in: 0..<3).elementsEqual(kNALStartCodeShort) {
        return (data.subdata(in: 3..<data.count), true)
    }
    return (data, false)
}

/// Skip HEVC NAL header (2 bytes: forbidden_zero_bit, nal_unit_type, nuh_layer_id, nuh_temporal_id_plus1) if present.
/// RPU NAL unit type in HEVC is often 62 (USER_DATA_UNREGISTERED). Returns index after NAL header or 0.
private func skipNALHeaderIfPresent(_ data: Data) -> Int {
    let bytes = [UInt8](data)
    guard bytes.count >= 2 else { return 0 }
    let nalType = (bytes[0] >> 1) & 0x3F
    // NAL type 62 = user data unregistered (Dolby Vision RPU in HEVC)
    if nalType == 62 || (nalType >= 0 && nalType <= 63) {
        return 2
    }
    return 0
}

// MARK: - Parser

public enum DolbyVisionRPUParser {
    private static let logCategory = "DolbyVisionRPU"

    /// Parse Dolby Vision RPU from a VANC structured payload (from DV-001).
    /// Returns non-nil only when `payload.dataType == .dolbyVision`; header may be nil if decode failed.
    public static func parse(_ vancPayload: VANCStructuredPayload) -> DolbyVisionRPU? {
        guard case .dolbyVision = vancPayload.dataType else { return nil }
        return parse(payload: vancPayload.payload, lineNumber: vancPayload.lineNumber)
    }

    /// Parse RPU from raw payload bytes (e.g. after DID 0x51, SDID 0x05).
    /// Strips optional NAL start code and NAL header; decodes base rpu_header when possible.
    public static func parse(payload: Data, lineNumber: UInt32 = 0) -> DolbyVisionRPU? {
        let (afterStart, hadStartCode) = stripNALStartCodeAndDetect(payload)
        var rbsp = afterStart
        if hadStartCode && afterStart.count >= 2 {
            let skip = skipNALHeaderIfPresent(afterStart)
            if skip > 0 {
                rbsp = afterStart.subdata(in: skip..<afterStart.count)
            }
        }
        guard !rbsp.isEmpty else {
            HDRLogger.debug(category: logCategory, "RPU payload empty after NAL strip")
            return DolbyVisionRPU(header: nil, rawPayload: payload, lineNumber: lineNumber)
        }
        let header = decodeRPUHeader(rbsp: rbsp)
        if let h = header {
            HDRLogger.debug(category: logCategory, "RPU parsed: \(h.formatVersion.displayName) (rpu_format=\(h.rpuFormat))")
        }
        return DolbyVisionRPU(header: header, rawPayload: payload, lineNumber: lineNumber)
    }

    /// Parse first Dolby Vision RPU from multiple VANC payloads.
    public static func parseFirst(from payloads: [VANCStructuredPayload]) -> DolbyVisionRPU? {
        for p in payloads {
            if let rpu = parse(p) { return rpu }
        }
        return nil
    }

    /// Decode base rpu_header from RPU RBSP (no NAL start code / NAL header).
    /// ST 2094-10 / dovi_tool order: rpu_nal_header (rpu_type 2b, rpu_format 10b), then rpu_header (variable).
    private static func decodeRPUHeader(rbsp: Data) -> DolbyVisionRPUHeader? {
        let bytes = [UInt8](rbsp)
        guard bytes.count >= 4 else {
            HDRLogger.debug(category: logCategory, "RPU RBSP too short for header: \(bytes.count)")
            return nil
        }
        var reader = BitReader(bytes: bytes)

        // rpu_nal_header: rpu_type (2), rpu_format (10)
        guard let rpuType = reader.readBits(2).map(UInt8.init), rpuType <= 3 else { return nil }
        guard let rpuFormat = reader.readBits(10).map(UInt16.init) else { return nil }

        // rpu_header: variable-length; try to read key fields (aligned with FFmpeg AVDOVIRpuDataHeader).
        // vdr_rpu_profile, vdr_rpu_level often follow; then UE-Golomb and flags.
        let vdrRpuProfile: UInt8 = (reader.readBits(4).map(UInt8.init)) ?? 0
        let vdrRpuLevel: UInt8 = (reader.readBits(4).map(UInt8.init)) ?? 0
        let chromaResamplingExplicitFilterFlag = reader.readBit() ?? false
        let coefDataType: UInt8 = (reader.readBits(2).map(UInt8.init)) ?? 0
        let coefLog2Denom: UInt8 = (reader.readBits(4).map(UInt8.init)) ?? 0
        let vdrRpuNormalizedIdc: UInt8 = (reader.readBits(2).map(UInt8.init)) ?? 0
        let blVideoFullRangeFlag = reader.readBit() ?? false
        // bl_bit_depth_minus_8 as UE then bl_bit_depth = 8 + value
        let blMinus8 = reader.readUE().map(Int.init) ?? 0
        let blBitDepth = UInt8(clamping: 8 + blMinus8)
        // el_bit_depth_minus_8 (and possibly ext_mapping_idc) — simplified: one UE
        let elMinus8 = reader.readUE().map(Int.init) ?? 0
        let elBitDepth = UInt8(clamping: 8 + elMinus8)
        let vdrMinus8 = reader.readUE().map(Int.init) ?? 0
        let vdrBitDepth = UInt8(clamping: 8 + vdrMinus8)
        let spatialResamplingFilterFlag = reader.readBit() ?? false
        let elSpatialResamplingFilterFlag = reader.readBit() ?? false
        let disableResidualFlag = reader.readBit() ?? false

        return DolbyVisionRPUHeader(
            rpuType: rpuType,
            rpuFormat: rpuFormat,
            vdrRpuProfile: vdrRpuProfile,
            vdrRpuLevel: vdrRpuLevel,
            chromaResamplingExplicitFilterFlag: chromaResamplingExplicitFilterFlag,
            coefDataType: coefDataType,
            coefLog2Denom: coefLog2Denom,
            vdrRpuNormalizedIdc: vdrRpuNormalizedIdc,
            blVideoFullRangeFlag: blVideoFullRangeFlag,
            blBitDepth: blBitDepth,
            elBitDepth: elBitDepth,
            vdrBitDepth: vdrBitDepth,
            spatialResamplingFilterFlag: spatialResamplingFilterFlag,
            elSpatialResamplingFilterFlag: elSpatialResamplingFilterFlag,
            disableResidualFlag: disableResidualFlag
        )
    }

    /// Advance reader past rpu_nal_header + rpu_header. For CMv4.0 (rpu_format == 4) skips optional extended_mapping_idc (2b) and mapping_id (UE).
    /// Caller must have already consumed rpu_nal_header (rpu_type 2b, rpu_format 10b); pass rpuFormat from that read.
    private static func advancePastRPUHeader(_ reader: inout BitReader, rpuFormat: UInt16) -> Bool {
        _ = reader.readBits(4)  // vdr_rpu_profile
        _ = reader.readBits(4) // vdr_rpu_level
        _ = reader.readBit()
        _ = reader.readBits(2)
        _ = reader.readBits(4)
        _ = reader.readBits(2)
        _ = reader.readBit()
        guard reader.readUE() != nil else { return false }  // bl_bit_depth_minus_8
        guard reader.readUE() != nil else { return false }  // el_bit_depth_minus_8
        guard reader.readUE() != nil else { return false }  // vdr_bit_depth_minus_8
        _ = reader.readBit()
        _ = reader.readBit()
        _ = reader.readBit()
        // CMv4.0 (rpu_format 4): optional extended_mapping_idc (2 bits); if 1 or 2, mapping_id (UE).
        if rpuFormat == 4 {
            guard let extIdc = reader.readBits(2) else { return false }
            if extIdc == 1 || extIdc == 2 {
                guard reader.readUE() != nil else { return false }
            }
        }
        return true
    }

    /// Decode Dolby Vision Level 1 metadata (min/max/avg PQ) from a parsed RPU.
    /// Parses RPU payload for L1 metadata block (SMPTE ST 2094-10); returns nil if L1 not present or parse fails.
    public static func decodeLevel1(from rpu: DolbyVisionRPU) -> DolbyVisionLevel1Metadata? {
        let (afterStart, hadStartCode) = stripNALStartCodeAndDetect(rpu.rawPayload)
        var rbsp = afterStart
        if hadStartCode && afterStart.count >= 2 {
            let skip = skipNALHeaderIfPresent(afterStart)
            if skip > 0 {
                rbsp = afterStart.subdata(in: skip..<afterStart.count)
            }
        }
        guard !rbsp.isEmpty else { return nil }
        let bytes = [UInt8](rbsp)
        var reader = BitReader(bytes: bytes)

        // rpu_nal_header
        guard reader.readBits(2) != nil, let rpuFormat = reader.readBits(10).map(UInt16.init) else { return nil }
        guard advancePastRPUHeader(&reader, rpuFormat: rpuFormat) else { return nil }

        // vdr_rpu_data(): use_metadata_block_list (1 bit)
        guard let useList = reader.readBit(), useList else {
            HDRLogger.debug(category: logCategory, "RPU has no metadata block list")
            return nil
        }
        guard let numBlocks = reader.readUE(), numBlocks > 0 else { return nil }

        for _ in 0..<numBlocks {
            guard let tag = reader.readUE(), let length = reader.readUE() else { break }
            // Level 1 metadata block tag (ST 2094-10: typically 1 for level1); payload 12+12+12 bits
            if tag == 1 && length >= 36 {
                guard let minBits = reader.readBits(12),
                      let maxBits = reader.readBits(12),
                      let avgBits = reader.readBits(12) else { break }
                let minPQ = UInt16(min(minBits, 4095))
                let maxPQ = UInt16(min(maxBits, 4095))
                let avgPQ = UInt16(min(avgBits, 4095))
                HDRLogger.debug(category: logCategory, "L1 decoded: min=\(minPQ) max=\(maxPQ) avg=\(avgPQ)")
                return DolbyVisionLevel1Metadata(minPQRaw: minPQ, maxPQRaw: maxPQ, avgPQRaw: avgPQ)
            }
            // Skip this block's payload (length in bits) when not L1
            for _ in 0..<length {
                _ = reader.readBit()
            }
        }
        return nil
    }

    /// Decode Dolby Vision Level 2 metadata (trims per target display) from a parsed RPU.
    /// Parses RPU payload for L2 metadata block (SMPTE ST 2094-10 tag 2); returns nil if L2 not present or parse fails.
    public static func decodeLevel2(from rpu: DolbyVisionRPU) -> DolbyVisionLevel2Metadata? {
        let (afterStart, hadStartCode) = stripNALStartCodeAndDetect(rpu.rawPayload)
        var rbsp = afterStart
        if hadStartCode && afterStart.count >= 2 {
            let skip = skipNALHeaderIfPresent(afterStart)
            if skip > 0 {
                rbsp = afterStart.subdata(in: skip..<afterStart.count)
            }
        }
        guard !rbsp.isEmpty else { return nil }
        let bytes = [UInt8](rbsp)
        var reader = BitReader(bytes: bytes)

        guard reader.readBits(2) != nil, let rpuFormat = reader.readBits(10).map(UInt16.init) else { return nil }
        guard advancePastRPUHeader(&reader, rpuFormat: rpuFormat) else { return nil }
        guard let useList = reader.readBit(), useList else { return nil }
        guard let numBlocks = reader.readUE(), numBlocks > 0 else { return nil }

        for _ in 0..<numBlocks {
            guard let tag = reader.readUE(), let length = reader.readUE() else { break }
            if tag == 2 && length >= 24 {
                guard let numTargets = reader.readUE(), numTargets > 0, numTargets <= 64 else { break }
                var trims: [DolbyVisionLevel2TargetTrim] = []
                let bitsPerTarget = 24
                let maxTargets = min(Int(numTargets), Int(truncatingIfNeeded: (length - 7) / UInt64(bitsPerTarget)))
                for _ in 0..<maxTargets {
                    guard let slopeBits = reader.readBits(12),
                          let offsetBits = reader.readBits(12) else { break }
                    trims.append(DolbyVisionLevel2TargetTrim(
                        trimSlopeRaw: UInt16(min(slopeBits, 4095)),
                        trimOffsetRaw: UInt16(min(offsetBits, 4095))
                    ))
                }
                if !trims.isEmpty {
                    HDRLogger.debug(category: logCategory, "L2 decoded: \(trims.count) target trim(s)")
                    return DolbyVisionLevel2Metadata(targetTrims: trims)
                }
            }
            for _ in 0..<length {
                _ = reader.readBit()
            }
        }
        return nil
    }

    /// Decode Dolby Vision Level 5 metadata (active area offsets) from a parsed RPU.
    /// Parses RPU payload for L5 metadata block (SMPTE ST 2094-10 tag 5); returns nil if L5 not present or parse fails.
    /// Field order matches FFmpeg AVDOVIDmLevel5: left_offset, right_offset, top_offset, bottom_offset (16-bit each).
    public static func decodeLevel5(from rpu: DolbyVisionRPU) -> DolbyVisionLevel5Metadata? {
        let (afterStart, hadStartCode) = stripNALStartCodeAndDetect(rpu.rawPayload)
        var rbsp = afterStart
        if hadStartCode && afterStart.count >= 2 {
            let skip = skipNALHeaderIfPresent(afterStart)
            if skip > 0 {
                rbsp = afterStart.subdata(in: skip..<afterStart.count)
            }
        }
        guard !rbsp.isEmpty else { return nil }
        let bytes = [UInt8](rbsp)
        var reader = BitReader(bytes: bytes)

        guard reader.readBits(2) != nil, let rpuFormat = reader.readBits(10).map(UInt16.init) else { return nil }
        guard advancePastRPUHeader(&reader, rpuFormat: rpuFormat) else { return nil }
        guard let useList = reader.readBit(), useList else { return nil }
        guard let numBlocks = reader.readUE(), numBlocks > 0 else { return nil }

        for _ in 0..<numBlocks {
            guard let tag = reader.readUE(), let length = reader.readUE() else { break }
            if tag == 5 && length >= 64 {
                guard let leftBits = reader.readBits(16),
                      let rightBits = reader.readBits(16),
                      let topBits = reader.readBits(16),
                      let bottomBits = reader.readBits(16) else { break }
                HDRLogger.debug(category: logCategory, "L5 decoded: left=\(leftBits) right=\(rightBits) top=\(topBits) bottom=\(bottomBits)")
                return DolbyVisionLevel5Metadata(
                    leftOffset: UInt16(leftBits),
                    rightOffset: UInt16(rightBits),
                    topOffset: UInt16(topBits),
                    bottomOffset: UInt16(bottomBits)
                )
            }
            for _ in 0..<length {
                _ = reader.readBit()
            }
        }
        return nil
    }

    /// Decode Dolby Vision Level 6 metadata (MaxCLL, MaxFALL) from a parsed RPU.
    /// Parses RPU payload for L6 metadata block (SMPTE ST 2094-10 tag 6); returns nil if L6 not present or parse fails.
    /// MaxCLL and MaxFALL are 16-bit values in cd/m² (1 LSB = 1 cd/m²); 0 means not specified.
    public static func decodeLevel6(from rpu: DolbyVisionRPU) -> DolbyVisionLevel6Metadata? {
        let (afterStart, hadStartCode) = stripNALStartCodeAndDetect(rpu.rawPayload)
        var rbsp = afterStart
        if hadStartCode && afterStart.count >= 2 {
            let skip = skipNALHeaderIfPresent(afterStart)
            if skip > 0 {
                rbsp = afterStart.subdata(in: skip..<afterStart.count)
            }
        }
        guard !rbsp.isEmpty else { return nil }
        let bytes = [UInt8](rbsp)
        var reader = BitReader(bytes: bytes)

        guard reader.readBits(2) != nil, let rpuFormat = reader.readBits(10).map(UInt16.init) else { return nil }
        guard advancePastRPUHeader(&reader, rpuFormat: rpuFormat) else { return nil }
        guard let useList = reader.readBit(), useList else { return nil }
        guard let numBlocks = reader.readUE(), numBlocks > 0 else { return nil }

        for _ in 0..<numBlocks {
            guard let tag = reader.readUE(), let length = reader.readUE() else { break }
            if tag == 6 && length >= 32 {
                guard let maxCLLBits = reader.readBits(16),
                      let maxFALLBits = reader.readBits(16) else { break }
                let maxCLL = UInt16(maxCLLBits)
                let maxFALL = UInt16(maxFALLBits)
                HDRLogger.debug(category: logCategory, "L6 decoded: MaxCLL=\(maxCLL) MaxFALL=\(maxFALL)")
                return DolbyVisionLevel6Metadata(maxCLL: maxCLL, maxFALL: maxFALL)
            }
            for _ in 0..<length {
                _ = reader.readBit()
            }
        }
        return nil
    }
}
