// HDR10StaticMetadata.swift
// SMPTE ST 2086 static metadata: mastering display primaries, white point, min/max luminance.
// Parsed from VANC payloads (DV-001); output type for DV-002.

import Foundation
import Logging
import Common
import Capture

// MARK: - ST 2086 mastering display color volume

/// Chromaticity coordinate (x or y) in CIE 1931 xy, normalized 0...1.
/// ST 2086 encodes as 16-bit with scale 0.00002 (1.0 = 50000).
public struct ChromaticityCoord: Sendable {
    public let value: Double

    public init(value: Double) {
        self.value = value
    }

    /// Decode from ST 2086 16-bit value (units of 0.00002).
    public static func fromST2086(_ u16: UInt16) -> ChromaticityCoord {
        ChromaticityCoord(value: Double(u16) / 50_000.0)
    }
}

/// Red, green, blue primary xy chromaticity (ST 2086).
public struct DisplayPrimaries: Sendable {
    public let redX: ChromaticityCoord
    public let redY: ChromaticityCoord
    public let greenX: ChromaticityCoord
    public let greenY: ChromaticityCoord
    public let blueX: ChromaticityCoord
    public let blueY: ChromaticityCoord

    public init(redX: ChromaticityCoord, redY: ChromaticityCoord,
                greenX: ChromaticityCoord, greenY: ChromaticityCoord,
                blueX: ChromaticityCoord, blueY: ChromaticityCoord) {
        self.redX = redX
        self.redY = redY
        self.greenX = greenX
        self.greenY = greenY
        self.blueX = blueX
        self.blueY = blueY
    }
}

/// White point xy (ST 2086).
public struct WhitePoint: Sendable {
    public let x: ChromaticityCoord
    public let y: ChromaticityCoord

    public init(x: ChromaticityCoord, y: ChromaticityCoord) {
        self.x = x
        self.y = y
    }
}

// MARK: - HDR10 static metadata (ST 2086)

/// Parsed SMPTE ST 2086 static metadata from VANC (mastering display color volume).
/// Input: VANC payload from DV-001 (DID 0x61, SDID 0x01). Output for DV-002.
public struct HDR10StaticMetadata: Sendable {
    public let displayPrimaries: DisplayPrimaries
    public let whitePoint: WhitePoint
    /// Max display mastering luminance in cd/m² (1...65535).
    public let maxDisplayMasteringLuminance: UInt16
    /// Min display mastering luminance in cd/m² (ST 2086: stored as 0.0001 cd/m² per LSB).
    public let minDisplayMasteringLuminance: Double

    public init(
        displayPrimaries: DisplayPrimaries,
        whitePoint: WhitePoint,
        maxDisplayMasteringLuminance: UInt16,
        minDisplayMasteringLuminance: Double
    ) {
        self.displayPrimaries = displayPrimaries
        self.whitePoint = whitePoint
        self.maxDisplayMasteringLuminance = maxDisplayMasteringLuminance
        self.minDisplayMasteringLuminance = minDisplayMasteringLuminance
    }

    /// Min luminance in cd/m² (converted from 0.0001 cd/m² units).
    public var minDisplayMasteringLuminanceCdM2: Double {
        minDisplayMasteringLuminance
    }
}

// MARK: - Parser (VANC payload → HDR10StaticMetadata)

/// ST 2086 payload layout (CTA-861-G / ST 2108-1): 20 bytes, big-endian.
/// Bytes 0–1: Red x, 2–3: Red y, 4–5: Green x, 6–7: Green y, 8–9: Blue x, 10–11: Blue y,
/// 12–13: White x, 14–15: White y, 16–17: Max luminance (1 cd/m² per LSB), 18–19: Min (0.0001 cd/m² per LSB).
private let kST2086PayloadLength = 20

public enum ST2086Parser {
    private static let logCategory = "ST2086"

    /// Parse ST 2086 static metadata from a VANC structured payload (from DV-001).
    /// Returns non-nil only when `payload.dataType == .hdr10Static` and payload length >= 20 bytes.
    public static func parse(_ vancPayload: VANCStructuredPayload) -> HDR10StaticMetadata? {
        guard case .hdr10Static = vancPayload.dataType else { return nil }
        return parse(payload: vancPayload.payload)
    }

    /// Parse ST 2086 from raw payload bytes (e.g. after DID 0x61, SDID 0x01).
    /// Big-endian 20-byte block; returns nil if length < 20.
    public static func parse(payload: Data) -> HDR10StaticMetadata? {
        guard payload.count >= kST2086PayloadLength else {
            HDRLogger.debug(category: logCategory, "ST 2086 payload too short: \(payload.count) bytes")
            return nil
        }
        let p = payload
        func be16(_ offset: Int) -> UInt16 {
            UInt16(p[offset]) << 8 | UInt16(p[offset + 1])
        }
        let redX = ChromaticityCoord.fromST2086(be16(0))
        let redY = ChromaticityCoord.fromST2086(be16(2))
        let greenX = ChromaticityCoord.fromST2086(be16(4))
        let greenY = ChromaticityCoord.fromST2086(be16(6))
        let blueX = ChromaticityCoord.fromST2086(be16(8))
        let blueY = ChromaticityCoord.fromST2086(be16(10))
        let whiteX = ChromaticityCoord.fromST2086(be16(12))
        let whiteY = ChromaticityCoord.fromST2086(be16(14))
        let maxLum = be16(16)
        let minLumRaw = be16(18)
        let minLumCdM2 = Double(minLumRaw) * 0.0001

        let primaries = DisplayPrimaries(
            redX: redX, redY: redY,
            greenX: greenX, greenY: greenY,
            blueX: blueX, blueY: blueY
        )
        let white = WhitePoint(x: whiteX, y: whiteY)
        return HDR10StaticMetadata(
            displayPrimaries: primaries,
            whitePoint: white,
            maxDisplayMasteringLuminance: maxLum,
            minDisplayMasteringLuminance: minLumCdM2
        )
    }

    /// Parse multiple VANC payloads; returns first valid HDR10 static metadata, if any.
    public static func parseFirst(from payloads: [VANCStructuredPayload]) -> HDR10StaticMetadata? {
        for p in payloads {
            if let meta = parse(p) { return meta }
        }
        return nil
    }
}
