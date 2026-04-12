import Foundation
import Logging
import Common
import Capture

/// Metadata pipeline (Phase 6: Dolby Vision, HDR10, HDR10+). DV-001: VANC line parser in VANCParser; feed AncillaryPacket from DL-009, get VANCStructuredPayload for DV-002+.
/// DV-011: Optional shared alerting for gap and error reporting; set sharedAlerting to enable. DV-012: HDR10+ (ST 2094-40) parsing.
public enum MetadataPipeline {
    /// Shared alerting instance for gap/error reporting. Set by app/capture layer; used by parseDolbyVisionRPUWithAlerting.
    public static var sharedAlerting: MetadataAlerting?

    public static func register() {
        HDRLogger.info(category: "Metadata", "MetadataPipeline registered (VANCParser, ST2086, Dolby Vision RPU, HDR10+, DV-011 alerting)")
    }

    /// Parse HDR10 static metadata (ST 2086) from ancillary packets (DL-009). Uses DV-001 VANC parser then DV-002 ST 2086 parser; returns first valid HDR10StaticMetadata if any.
    public static func parseHDR10Static(from packets: [AncillaryPacket]) -> HDR10StaticMetadata? {
        let payloads = VANCParser.parse(packets: packets)
        return ST2086Parser.parseFirst(from: payloads)
    }

    /// Parse HDR10 static metadata from a single VANC structured payload (e.g. from VANCParser.parse).
    public static func parseHDR10Static(from vancPayload: VANCStructuredPayload) -> HDR10StaticMetadata? {
        ST2086Parser.parse(vancPayload)
    }

    /// Parse Dolby Vision RPU (SMPTE ST 2094-10) from ancillary packets (DL-009). Uses DV-001 VANC then DV-003 RPU parser; returns first RPU if any (header + raw payload for DV-004+).
    public static func parseDolbyVisionRPU(from packets: [AncillaryPacket]) -> DolbyVisionRPU? {
        let payloads = VANCParser.parse(packets: packets)
        return DolbyVisionRPUParser.parseFirst(from: payloads)
    }

    /// Parse Dolby Vision RPU from a single VANC structured payload (e.g. from VANCParser.parse).
    public static func parseDolbyVisionRPU(from vancPayload: VANCStructuredPayload) -> DolbyVisionRPU? {
        DolbyVisionRPUParser.parse(vancPayload)
    }

    /// Parse HDR10+ dynamic metadata (SMPTE ST 2094-40) from ancillary packets (DL-009). Uses DV-001 VANC then HDR10+ parser; returns first valid if any.
    public static func parseHDR10Plus(from packets: [AncillaryPacket]) -> HDR10PlusDynamicMetadata? {
        let payloads = VANCParser.parse(packets: packets)
        return HDR10PlusParser.parseFirst(from: payloads)
    }

    /// Parse HDR10+ from a single VANC structured payload (e.g. from VANCParser.parse).
    public static func parseHDR10Plus(from vancPayload: VANCStructuredPayload) -> HDR10PlusDynamicMetadata? {
        HDR10PlusParser.parse(vancPayload)
    }

    /// Parse Dolby Vision RPU and decode Level 1 (min/max/avg PQ) when present. For UI/QC display.
    public static func parseDolbyVisionRPUWithLevel1(from packets: [AncillaryPacket]) -> (rpu: DolbyVisionRPU, level1: DolbyVisionLevel1Metadata?)? {
        guard let rpu = parseDolbyVisionRPU(from: packets) else { return nil }
        return (rpu, rpu.level1)
    }

    /// Parse Dolby Vision RPU and decode Level 2 (trims per target display) when present. For UI/QC display.
    public static func parseDolbyVisionRPUWithLevel2(from packets: [AncillaryPacket]) -> (rpu: DolbyVisionRPU, level2: DolbyVisionLevel2Metadata?)? {
        guard let rpu = parseDolbyVisionRPU(from: packets) else { return nil }
        return (rpu, rpu.level2)
    }

    /// Parse Dolby Vision RPU and decode Level 5 (active area offsets) when present. For UI/QC display.
    public static func parseDolbyVisionRPUWithLevel5(from packets: [AncillaryPacket]) -> (rpu: DolbyVisionRPU, level5: DolbyVisionLevel5Metadata?)? {
        guard let rpu = parseDolbyVisionRPU(from: packets) else { return nil }
        return (rpu, rpu.level5)
    }

    /// Parse Dolby Vision RPU and decode Level 6 (MaxCLL, MaxFALL) when present. For UI/QC display.
    public static func parseDolbyVisionRPUWithLevel6(from packets: [AncillaryPacket]) -> (rpu: DolbyVisionRPU, level6: DolbyVisionLevel6Metadata?)? {
        guard let rpu = parseDolbyVisionRPU(from: packets) else { return nil }
        return (rpu, rpu.level6)
    }

    // MARK: - DV-011 Alerting

    /// Parse Dolby Vision RPU and feed result to sharedAlerting when set. Call every frame (with current frame's packets) for gap detection.
    /// When parse fails despite DV payload present, or RPU header decode fails, reports error to alerting.
    public static func parseDolbyVisionRPUWithAlerting(from packets: [AncillaryPacket], frameIndex: UInt64) -> DolbyVisionRPU? {
        let payloads = VANCParser.parse(packets: packets)
        let hasDVPayload = payloads.contains { if case .dolbyVision = $0.dataType { return true }; return false }
        guard let rpu = DolbyVisionRPUParser.parseFirst(from: payloads) else {
            sharedAlerting?.feedFrame(frameIndex: frameIndex, dolbyVisionRPU: nil, hdr10Static: nil)
            if hasDVPayload, let alerting = sharedAlerting {
                alerting.reportError(.parseFailure, message: "Dolby Vision payload present but RPU parse failed", frameIndex: frameIndex)
            }
            return nil
        }
        if rpu.header == nil, let alerting = sharedAlerting {
            alerting.reportError(.corruptPayload, message: "RPU payload too short or header decode failed", frameIndex: frameIndex)
        }
        let hdr10 = payloads.compactMap { parseHDR10Static(from: $0) }.first
        sharedAlerting?.feedFrame(frameIndex: frameIndex, dolbyVisionRPU: rpu, hdr10Static: hdr10)
        return rpu
    }
}
