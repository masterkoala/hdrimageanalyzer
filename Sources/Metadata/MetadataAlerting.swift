// MetadataAlerting.swift
// DV-011: Metadata gap and error alerting. Detects gaps (missing expected metadata) and records parse/version/corrupt errors.
// Integrates with Logging (HDRLogger, QCEvent) for timecoded QC and export.

import Foundation
import Logging
import Common
import Capture

// MARK: - Alert / error kinds

/// Kind of metadata error for alerting and QC.
public enum MetadataErrorKind: Sendable {
    case parseFailure
    case versionMismatch
    case corruptPayload
    case vancValidation
}

/// A single metadata alert: either a gap (missing expected metadata) or an error (parse/version/corrupt).
public struct MetadataAlert: Sendable {
    public enum Kind: Sendable {
        case gap(framesMissing: UInt64, metadataType: String)
        case error(kind: MetadataErrorKind, message: String)
    }
    public let kind: Kind
    public let frameIndex: UInt64?
    public let timestamp: Date

    public init(kind: Kind, frameIndex: UInt64? = nil, timestamp: Date = Date()) {
        self.kind = kind
        self.frameIndex = frameIndex
        self.timestamp = timestamp
    }

    public var description: String {
        switch kind {
        case .gap(let framesMissing, let metadataType):
            return "Metadata gap: no \(metadataType) for \(framesMissing) consecutive frames"
        case .error(let errorKind, let message):
            return "Metadata error (\(errorKind)): \(message)"
        }
    }
}

// MARK: - Alerting state machine

/// Thread-safe metadata gap and error alerting. Feed per-frame parse results; gaps and errors are logged and emitted as QC events.
public final class MetadataAlerting: @unchecked Sendable {
    private static let logCategory = "MetadataAlerting"
    private let lock = NSLock()

    /// Frames without RPU before a gap alert is raised (default 30).
    public var gapThresholdFrames: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _gapThresholdFrames
        }
        set {
            lock.lock()
            _gapThresholdFrames = max(1, newValue)
            lock.unlock()
        }
    }
    private var _gapThresholdFrames: Int = 30

    private var hasSeenDolbyVisionRPU: Bool = false
    private var consecutiveFramesWithoutRPU: Int = 0
    private var lastFrameWithRPU: UInt64 = 0

    /// Optional callback for UI (e.g. show banner). Called on same thread as feedFrame/reportError.
    public var onAlert: ((MetadataAlert) -> Void)?

    public init(gapThresholdFrames: Int = 30) {
        self._gapThresholdFrames = max(1, gapThresholdFrames)
    }

    /// Feed one frame's metadata. Call every frame from capture/UI. Gap alert is raised once when consecutive missing frames reach threshold.
    public func feedFrame(frameIndex: UInt64, dolbyVisionRPU: DolbyVisionRPU?, hdr10Static: HDR10StaticMetadata?) {
        lock.lock()
        if dolbyVisionRPU != nil {
            hasSeenDolbyVisionRPU = true
            consecutiveFramesWithoutRPU = 0
            lastFrameWithRPU = frameIndex
            lock.unlock()
            return
        }
        if hasSeenDolbyVisionRPU {
            consecutiveFramesWithoutRPU += 1
            let threshold = _gapThresholdFrames
            let count = consecutiveFramesWithoutRPU
            lock.unlock()
            if count == threshold {
                let alert = MetadataAlert(
                    kind: .gap(framesMissing: UInt64(threshold), metadataType: "Dolby Vision RPU"),
                    frameIndex: frameIndex,
                    timestamp: Date()
                )
                emitAlert(alert)
            }
            return
        }
        lock.unlock()
    }

    /// Report a metadata error (parse failure, version mismatch, corrupt payload, VANC validation). Logs and emits QC event.
    public func reportError(_ kind: MetadataErrorKind, message: String, frameIndex: UInt64? = nil) {
        let alert = MetadataAlert(kind: .error(kind: kind, message: message), frameIndex: frameIndex, timestamp: Date())
        emitAlert(alert)
    }

    private func emitAlert(_ alert: MetadataAlert) {
        let desc = alert.description
        HDRLogger.error(category: Self.logCategory, desc)
        let qcKind: QCEventKind
        switch alert.kind {
        case .gap:
            qcKind = .metadataError
        case .error:
            qcKind = .dolbyVisionRpuError
        }
        let event = QCEvent(
            kind: qcKind,
            severity: .warning,
            timecode: nil,
            channel: "metadata",
            value: alert.frameIndex.map { Double($0) },
            threshold: nil,
            description: desc,
            timestamp: alert.timestamp
        )
        HDRLogger.logQC(event)
        onAlert?(alert)
    }

    /// Reset gap state (e.g. new source or stream). Error history is in QC buffer; this only clears gap counters.
    public func resetGapState() {
        lock.lock()
        hasSeenDolbyVisionRPU = false
        consecutiveFramesWithoutRPU = 0
        lastFrameWithRPU = 0
        lock.unlock()
    }
}

