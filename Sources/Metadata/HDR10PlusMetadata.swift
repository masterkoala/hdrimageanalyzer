// HDR10PlusMetadata.swift
// Parse HDR10+ dynamic metadata (SMPTE ST 2094-40) from VANC payloads (DV-001).
// Application #4 color volume transform; T.35 optional prefix then ST 2094-40 payload.
// Reference: CTA-861-G, SMPTE ST 2094-40, FFmpeg AVDynamicHDRPlus.

import Foundation
import Logging
import Common
import Capture

// MARK: - T.35 / Application header

/// ITU-T T.35 header for HDR10+ in SEI/VANC: 0x003C 0x0001, application_id 4, application_mode 1.
private let kT35Prefix: [UInt8] = [0x00, 0x3C, 0x00, 0x01, 0x04, 0x01]
private let kT35PrefixLength = 6

// MARK: - HDR10+ window parameters (ST 2094-40)

/// Per-window HDR10+ parameters (ST 2094-40). MaxSCL and distribution values; window in normalized 0..1.
public struct HDR10PlusWindowParams: Sendable {
    /// Window upper-left x (normalized 0–1, or 0 if full frame).
    public let windowUpperLeftX: Double
    /// Window upper-left y (normalized 0–1).
    public let windowUpperLeftY: Double
    /// Window lower-right x (normalized 0–1).
    public let windowLowerRightX: Double
    /// Window lower-right y (normalized 0–1).
    public let windowLowerRightY: Double
    /// Maximum scene color component levels [R, G, B] normalized 0–1 (PQ or linear per spec).
    public let maxscl: [Double]
    /// Average of max RGB (normalized).
    public let averageMaxRGB: Double
    /// Distribution max RGB percentiles (up to 15 values); empty if not present.
    public let distributionMaxRGBPercentiles: [Double]

    public init(
        windowUpperLeftX: Double,
        windowUpperLeftY: Double,
        windowLowerRightX: Double,
        windowLowerRightY: Double,
        maxscl: [Double],
        averageMaxRGB: Double,
        distributionMaxRGBPercentiles: [Double]
    ) {
        self.windowUpperLeftX = windowUpperLeftX
        self.windowUpperLeftY = windowUpperLeftY
        self.windowLowerRightX = windowLowerRightX
        self.windowLowerRightY = windowLowerRightY
        self.maxscl = maxscl
        self.averageMaxRGB = averageMaxRGB
        self.distributionMaxRGBPercentiles = distributionMaxRGBPercentiles
    }
}

// MARK: - HDR10+ dynamic metadata (ST 2094-40)

/// Parsed HDR10+ dynamic metadata (SMPTE ST 2094-40 Application #4).
/// Input: VANC payload from DV-001 (DID 0x61, SDID 0x02) or SEI with T.35 prefix.
public struct HDR10PlusDynamicMetadata: Sendable {
    /// Application identifier (4 = HDR10+ color volume transform).
    public let applicationIdentifier: UInt8
    /// Application version (0 or 1 per ST 2094-40).
    public let applicationVersion: UInt8
    /// Number of processing windows (1 or 3).
    public let numWindows: Int
    /// Per-window parameters; count equals numWindows.
    public let windowParams: [HDR10PlusWindowParams]
    /// Targeted system display actual peak luminance present (optional 2D array in spec).
    public let targetedSystemDisplayActualPeakLuminanceFlag: Bool
    /// Raw payload bytes (after optional T.35 strip) for downstream or re-parse.
    public let rawPayload: Data

    public init(
        applicationIdentifier: UInt8,
        applicationVersion: UInt8,
        numWindows: Int,
        windowParams: [HDR10PlusWindowParams],
        targetedSystemDisplayActualPeakLuminanceFlag: Bool,
        rawPayload: Data
    ) {
        self.applicationIdentifier = applicationIdentifier
        self.applicationVersion = applicationVersion
        self.numWindows = numWindows
        self.windowParams = windowParams
        self.targetedSystemDisplayActualPeakLuminanceFlag = targetedSystemDisplayActualPeakLuminanceFlag
        self.rawPayload = rawPayload
    }
}

// MARK: - Bit reader for ST 2094-40

private struct HDR10PlusBitReader {
    private let bytes: [UInt8]
    private var byteOffset: Int = 0
    private var bitOffset: Int = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var bitsRemaining: Int {
        max(0, (bytes.count - byteOffset) * 8 - bitOffset)
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

    /// Unsigned exponential Golomb (ue(v)).
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

// MARK: - Parser

public enum HDR10PlusParser {
    private static let logCategory = "HDR10Plus"

    /// Parse HDR10+ (ST 2094-40) from a VANC structured payload (from DV-001).
    /// Returns non-nil only when `payload.dataType == .hdr10Plus` and payload is valid.
    public static func parse(_ vancPayload: VANCStructuredPayload) -> HDR10PlusDynamicMetadata? {
        guard case .hdr10Plus = vancPayload.dataType else { return nil }
        return parse(payload: vancPayload.payload)
    }

    /// Parse HDR10+ from raw payload bytes. Skips optional T.35 prefix (6 bytes) then parses ST 2094-40.
    public static func parse(payload: Data) -> HDR10PlusDynamicMetadata? {
        var data = payload
        if data.count >= kT35PrefixLength,
           data.subdata(in: 0..<kT35PrefixLength).elementsEqual(kT35Prefix) {
            data = data.subdata(in: kT35PrefixLength..<data.count)
        }
        guard data.count >= 2 else {
            HDRLogger.debug(category: logCategory, "HDR10+ payload too short: \(data.count) bytes")
            return nil
        }
        let bytes = [UInt8](data)
        var reader = HDR10PlusBitReader(bytes: bytes)

        // application_identifier (4 bits), application_version (4 bits)
        guard let appId = reader.readBits(4).map(UInt8.init),
              let appVer = reader.readBits(4).map(UInt8.init) else { return nil }
        guard appId == 4 else {
            HDRLogger.debug(category: logCategory, "HDR10+ application_id != 4: \(appId)")
            return nil
        }

        // num_windows_minus1 (ue); 0 => 1 window, 2 => 3 windows
        guard let numWindowsM1 = reader.readUE() else { return nil }
        let numWindows = numWindowsM1 == 0 ? 1 : (numWindowsM1 == 2 ? 3 : Int(numWindowsM1) + 1)
        guard numWindows >= 1, numWindows <= 3 else {
            HDRLogger.debug(category: logCategory, "HDR10+ num_windows out of range: \(numWindows)")
            return nil
        }

        var windowParams: [HDR10PlusWindowParams] = []
        for _ in 0..<numWindows {
            // Window bounds: 16-bit each, normalized by 50000 (CTA-861-G / ST 2094-40)
            let wx0 = (reader.readBits(16).map { Double($0) / 50000.0 }) ?? 0
            let wy0 = (reader.readBits(16).map { Double($0) / 50000.0 }) ?? 0
            let wx1 = (reader.readBits(16).map { Double($0) / 50000.0 }) ?? 1
            let wy1 = (reader.readBits(16).map { Double($0) / 50000.0 }) ?? 1

            // maxscl[0..3]: 17-bit values, scale 0..1 by (1<<17)
            var maxscl: [Double] = (0..<4).compactMap { _ in reader.readBits(17).map { Double($0) / Double(1 << 17) } }
            if maxscl.count < 4 { maxscl.append(contentsOf: [Double](repeating: 0, count: 4 - maxscl.count)) }

            // average_maxrgb: 17-bit
            let avgMaxRGB = reader.readBits(17).map { Double($0) / Double(1 << 17) } ?? 0

            // distribution_maxrgb_percentiles: num (4 bits), then 17-bit value per entry
            var distribution: [Double] = []
            if let numPct = reader.readBits(4).map(Int.init), numPct > 0 {
                for _ in 0..<min(numPct, 15) {
                    if let pct = reader.readBits(17).map({ Double($0) / Double(1 << 17) }) { distribution.append(pct) }
                }
            }

            windowParams.append(HDR10PlusWindowParams(
                windowUpperLeftX: wx0,
                windowUpperLeftY: wy0,
                windowLowerRightX: wx1,
                windowLowerRightY: wy1,
                maxscl: maxscl,
                averageMaxRGB: avgMaxRGB,
                distributionMaxRGBPercentiles: distribution
            ))
        }

        // targeted_system_display_actual_peak_luminance_flag (1 bit)
        let targetedPeakFlag = reader.readBit() ?? false

        HDRLogger.debug(category: logCategory, "HDR10+ parsed: app_ver=\(appVer) num_windows=\(numWindows) targeted_peak=\(targetedPeakFlag)")

        return HDR10PlusDynamicMetadata(
            applicationIdentifier: appId,
            applicationVersion: appVer,
            numWindows: numWindows,
            windowParams: windowParams,
            targetedSystemDisplayActualPeakLuminanceFlag: targetedPeakFlag,
            rawPayload: data
        )
    }

    /// Parse first valid HDR10+ from multiple VANC payloads.
    public static func parseFirst(from payloads: [VANCStructuredPayload]) -> HDR10PlusDynamicMetadata? {
        for p in payloads {
            if let meta = parse(p) { return meta }
        }
        return nil
    }
}
