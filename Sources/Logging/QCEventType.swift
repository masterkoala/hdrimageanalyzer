import Foundation

/// QC event type registry (Phase 8, QC-001). All possible QC events for HDR/signal analysis.
/// Integrates with F-003 structured logging via HDRLogger.logQC(_:).
public enum QCEventKind: String, Codable, CaseIterable, Sendable {
    // Video / color
    case gamutViolation = "gamut_violation"
    case luminanceExceedance = "luminance_exceedance"
    case luminanceBelow = "luminance_below"
    case blackClipping = "black_clipping"
    case whiteClipping = "white_clipping"
    case freezeFrame = "freeze_frame"
    case blackFrame = "black_frame"

    // Audio
    case audioPeakOverload = "audio_peak_overload"
    case audioLoudnessExceedance = "audio_loudness_exceedance"
    case audioLevelUnder = "audio_level_under"
    case audioPhaseError = "audio_phase_error"

    // Signal / capture
    case signalLoss = "signal_loss"
    case formatChange = "format_change"
    case droppedFrame = "dropped_frame"
    case timecodeBreak = "timecode_break"
    case deviceChange = "device_change"

    // Metadata
    case metadataError = "metadata_error"
    case dolbyVisionRpuError = "dolby_vision_rpu_error"
    case hdr10MetadataError = "hdr10_metadata_error"

    // Generic
    case other = "other"

    public var displayName: String {
        switch self {
        case .gamutViolation: return "Gamut violation"
        case .luminanceExceedance: return "Luminance exceedance"
        case .luminanceBelow: return "Luminance below range"
        case .blackClipping: return "Black clipping"
        case .whiteClipping: return "White clipping"
        case .freezeFrame: return "Freeze frame"
        case .blackFrame: return "Black frame"
        case .audioPeakOverload: return "Audio peak overload"
        case .audioLoudnessExceedance: return "Audio loudness exceedance"
        case .audioLevelUnder: return "Audio level under"
        case .audioPhaseError: return "Audio phase error"
        case .signalLoss: return "Signal loss"
        case .formatChange: return "Format change"
        case .droppedFrame: return "Dropped frame"
        case .timecodeBreak: return "Timecode break"
        case .deviceChange: return "Device change"
        case .metadataError: return "Metadata error"
        case .dolbyVisionRpuError: return "Dolby Vision RPU error"
        case .hdr10MetadataError: return "HDR10 metadata error"
        case .other: return "Other"
        }
    }
}

/// Severity for QC events (maps to log level and export).
public enum QCEventSeverity: String, Codable, CaseIterable, Sendable {
    case info
    case warning
    case error
    case critical
}

/// A single QC event: kind, severity, optional timecode/channel/value, and description.
/// Used for timecoded event logging (QC-004), CSV/XML export (QC-005, QC-006), and F-003 logging.
public struct QCEvent: Sendable {
    public let kind: QCEventKind
    public let severity: QCEventSeverity
    public let timecode: String?
    public let channel: String?
    public let value: Double?
    public let threshold: Double?
    public let description: String
    public let timestamp: Date

    public init(
        kind: QCEventKind,
        severity: QCEventSeverity,
        timecode: String? = nil,
        channel: String? = nil,
        value: Double? = nil,
        threshold: Double? = nil,
        description: String,
        timestamp: Date = Date()
    ) {
        self.kind = kind
        self.severity = severity
        self.timecode = timecode
        self.channel = channel
        self.value = value
        self.threshold = threshold
        self.description = description
        self.timestamp = timestamp
    }

    /// One-line log message for F-003 (OSLog + file).
    public var logMessage: String {
        var parts: [String] = [kind.rawValue, severity.rawValue, description]
        if let tc = timecode, !tc.isEmpty { parts.append("tc=\(tc)") }
        if let ch = channel, !ch.isEmpty { parts.append("ch=\(ch)") }
        if let v = value { parts.append("value=\(v)") }
        if let t = threshold { parts.append("threshold=\(t)") }
        return parts.joined(separator: " | ")
    }
}
