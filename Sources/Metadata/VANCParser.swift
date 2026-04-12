// VANCParser.swift
// VANC line parser: parse ancillary packets from DL-009, extract payload for Dolby Vision / HDR10.
// SMPTE 291M line structure; output structured data for DV-002+.

import Foundation
import Logging
import Common
import Capture

// MARK: - VANC packet header (SMPTE 291M 8-bit)

/// First 4 bytes of a VANC packet in 8-bit format: DC, DID, SDID, DC.
private let kVANCHeaderLength = 4

/// Known DID/SDID for HDR metadata (SMPTE / vendor).
public enum VANCDataType: Sendable {
    /// Dolby Vision (SMPTE ST 2094-10); DID 0x51, SDID 0x05 typical.
    case dolbyVision
    /// HDR10 static metadata (SMPTE ST 2086); DID 0x61, SDID 0x01.
    case hdr10Static
    /// HDR10+ dynamic metadata (SMPTE ST 2094-40); DID 0x61, SDID 0x02 (CTA-861-G / vendor).
    case hdr10Plus
    /// Other; DID/SDID not in known set.
    case other(did: UInt8, sdid: UInt8)
}

// MARK: - Structured VANC payload (output for DV-002+)

/// Parsed VANC payload: line, type, and raw payload bytes for downstream (DV-002, DV-003).
public struct VANCStructuredPayload: Sendable {
    public let lineNumber: UInt32
    public let dataSpace: UInt32
    public let dataType: VANCDataType
    public let payload: Data

    public init(lineNumber: UInt32, dataSpace: UInt32, dataType: VANCDataType, payload: Data) {
        self.lineNumber = lineNumber
        self.dataSpace = dataSpace
        self.dataType = dataType
        self.payload = payload
    }
}

// MARK: - DID/SDID constants (SMPTE / Dolby)

private let kDIDDolbyVision: UInt8 = 0x51
private let kSDIDDolbyVision: UInt8 = 0x05
private let kDIDHDR10Static: UInt8 = 0x61
private let kSDIDHDR10Static: UInt8 = 0x01
private let kDIDHDR10Plus: UInt8 = 0x61
private let kSDIDHDR10Plus: UInt8 = 0x02

// MARK: - Parser

/// Parses ancillary packets (from DL-009), validates line structure, extracts VANC payload for Dolby Vision / HDR10.
public enum VANCParser {
    private static let logCategory = "VANCParser"

    /// Classify DID/SDID into metadata type.
    public static func dataType(did: UInt8, sdid: UInt8) -> VANCDataType {
        if did == kDIDDolbyVision && sdid == kSDIDDolbyVision { return .dolbyVision }
        if did == kDIDHDR10Static && sdid == kSDIDHDR10Static { return .hdr10Static }
        if did == kDIDHDR10Plus && sdid == kSDIDHDR10Plus { return .hdr10Plus }
        return .other(did: did, sdid: sdid)
    }

    /// Parse one ancillary packet into structured payload.
    /// - Parameter packet: From DL-009 (bytes, line, DID, SDID, dataSpace).
    /// - Returns: Structured payload if valid; nil if too short or invalid header.
    public static func parse(_ packet: AncillaryPacket) -> VANCStructuredPayload? {
        let data = packet.data
        let lineNumber = packet.lineNumber
        let did = packet.did
        let sdid = packet.sdid
        let dataSpace = packet.dataSpace

        // Only VANC (dataSpace 0) is parsed for DV/HDR10 payload extraction.
        guard dataSpace == 0 else { return nil }

        if data.count < kVANCHeaderLength {
            HDRLogger.debug(category: logCategory, "VANC packet too short: \(data.count) bytes")
            return nil
        }

        // SMPTE 291M 8-bit: [DC, DID, SDID, DC]
        let dc = data[0]
        let didInPacket = data[1]
        let sdidInPacket = data[2]
        let dcRepeat = data[3]

        if dc != dcRepeat {
            HDRLogger.debug(category: logCategory, "VANC DC mismatch: \(dc) vs \(dcRepeat)")
            return nil
        }
        if didInPacket != did || sdidInPacket != sdid {
            HDRLogger.debug(category: logCategory, "VANC DID/SDID mismatch packet(\(didInPacket),\(sdidInPacket)) vs api(\(did),\(sdid))")
            return nil
        }

        let payloadLength = min(Int(dc), data.count - kVANCHeaderLength)
        let payload: Data
        if payloadLength > 0 {
            payload = data.subdata(in: kVANCHeaderLength ..< (kVANCHeaderLength + payloadLength))
        } else {
            payload = Data()
        }

        let dataType = Self.dataType(did: did, sdid: sdid)
        return VANCStructuredPayload(
            lineNumber: lineNumber,
            dataSpace: dataSpace,
            dataType: dataType,
            payload: payload
        )
    }

    /// Parse multiple ancillary packets; returns only valid VANC (dataSpace 0) structured payloads.
    public static func parse(packets: [AncillaryPacket]) -> [VANCStructuredPayload] {
        packets.compactMap { parse($0) }
    }
}
