import Foundation

/// QC-012: Signal continuity monitoring — black frame and freeze frame detection.
/// Feed per-frame metrics (average luminance, frame signature) from the pipeline; emits
/// .blackFrame and .freezeFrame QCEvents via HDRLogger.logQC. Integrates with TimecodedQCContext for timecode.
public final class SignalContinuityMonitor: @unchecked Sendable {
    private let lock = NSLock()

    /// Average luminance in [0,1] (linear). Below blackFrameLuminanceThreshold → black frame.
    public var blackFrameLuminanceThreshold: Double = 0.01
    /// Consecutive frames with same signature to report freeze (avoid single duplicate).
    public var consecutiveFreezeFramesToReport: Int = 5

    private var lastFrameSignature: UInt64?
    private var consecutiveSameSignature: Int = 0
    private var lastBlackFrameReportedAt: Date?
    private let blackFrameReportCooldown: TimeInterval = 1.0

    public init() {}

    /// Call once per frame with metrics from the pipeline (e.g. GPU readback).
    /// - Parameters:
    ///   - avgLuminance: Average luminance of the frame in [0,1]. Nil to skip black detection.
    ///   - frameSignature: Hash/signature for this frame; same value on consecutive frames → freeze. Nil to skip freeze detection.
    public func feedFrame(avgLuminance: Double?, frameSignature: UInt64?) {
        lock.lock()
        defer { lock.unlock() }

        if let lum = avgLuminance, lum < blackFrameLuminanceThreshold {
            let now = Date()
            if lastBlackFrameReportedAt == nil || now.timeIntervalSince(lastBlackFrameReportedAt!) >= blackFrameReportCooldown {
                lastBlackFrameReportedAt = now
                let event = QCEvent(
                    kind: .blackFrame,
                    severity: .warning,
                    timecode: nil,
                    channel: nil,
                    value: lum,
                    threshold: blackFrameLuminanceThreshold,
                    description: "Black frame detected (avg luminance \(String(format: "%.4f", lum)) < \(blackFrameLuminanceThreshold))",
                    timestamp: now
                )
                HDRLogger.logQC(event)
            }
        }

        if let sig = frameSignature {
            if sig == lastFrameSignature {
                consecutiveSameSignature += 1
                if consecutiveSameSignature == consecutiveFreezeFramesToReport {
                    let event = QCEvent(
                        kind: .freezeFrame,
                        severity: .warning,
                        timecode: nil,
                        channel: nil,
                        value: Double(consecutiveSameSignature),
                        threshold: Double(consecutiveFreezeFramesToReport),
                        description: "Freeze frame detected (\(consecutiveSameSignature) identical frames)",
                        timestamp: Date()
                    )
                    HDRLogger.logQC(event)
                }
            } else {
                lastFrameSignature = sig
                consecutiveSameSignature = 1
            }
        }
    }

    /// Reset state (e.g. on new capture or source change).
    public func reset() {
        lock.lock()
        lastFrameSignature = nil
        consecutiveSameSignature = 0
        lastBlackFrameReportedAt = nil
        lock.unlock()
    }
}
