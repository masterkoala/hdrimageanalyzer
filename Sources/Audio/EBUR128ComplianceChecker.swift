import Foundation
import Logging

/// Audio level compliance checker for EBU R128 (QC-011).
/// Uses integrated loudness from AU-006 EBUR128LoudnessMeter and optional true peak from TruePeakDetector.
/// Emits QC events (.audioLoudnessExceedance, .audioPeakOverload) via HDRLogger.logQC when limits are exceeded.
///
/// EBU R128 limits:
/// - Integrated loudness: -23 LUFS target; default tolerance ±1 LU (acceptable range -24 to -22 LUFS).
/// - Max true peak: -1 dBTP (no peak above -1 dBTP).
public final class EBUR128ComplianceChecker {
    /// EBU R128 integrated loudness target in LUFS.
    public static let defaultIntegratedTargetLKFS: Float = -23.0
    /// Default tolerance in LU: integrated must be in [target - tolerance, target + tolerance].
    public static let defaultIntegratedToleranceLU: Float = 1.0
    /// EBU R128 max true peak in dBTP (no sample or inter-sample peak above this).
    public static let defaultMaxTruePeakDBTP: Float = -1.0

    /// Linear amplitude corresponding to -1 dBTP: 10^(-1/20).
    private static let linearMaxTruePeak: Float = 0.89125

    private let integratedTargetLKFS: Float
    private let integratedToleranceLU: Float
    private let maxTruePeakLinear: Float

    /// Cooldown between same-kind events to avoid log flood (seconds).
    private let eventCooldownSeconds: TimeInterval
    private var lastIntegratedExceedanceTime: Date?
    private var lastTruePeakOverloadTime: Date?
    private let lock = NSLock()

    /// - Parameters:
    ///   - integratedTargetLKFS: Target integrated loudness (default -23 LUFS).
    ///   - integratedToleranceLU: Tolerance in LU; integrated outside [target - tolerance, target + tolerance] triggers exceedance (default 1).
    ///   - maxTruePeakDBTP: Max allowed true peak in dBTP (default -1).
    ///   - eventCooldownSeconds: Min seconds between same-kind QC events (default 2).
    public init(
        integratedTargetLKFS: Float = -23.0,
        integratedToleranceLU: Float = 1.0,
        maxTruePeakDBTP: Float = -1.0,
        eventCooldownSeconds: TimeInterval = 2.0
    ) {
        self.integratedTargetLKFS = integratedTargetLKFS
        self.integratedToleranceLU = integratedToleranceLU
        self.maxTruePeakLinear = pow(10.0, maxTruePeakDBTP / 20.0)
        self.eventCooldownSeconds = eventCooldownSeconds
    }

    /// Runs compliance check: integrated loudness (and optionally true peak).
    /// Call periodically from the same thread that runs the meters (e.g. after process(from:) on the ring buffer).
    /// Emits QC events when limits are exceeded (subject to cooldown).
    /// - Parameters:
    ///   - loudnessMeter: EBUR128LoudnessMeter (AU-006); integrated loudness is read from here.
    ///   - truePeakDetector: Optional; if provided, true peak is checked against -1 dBTP.
    ///   - timecode: Optional timecode for emitted events.
    public func check(
        loudnessMeter: EBUR128LoudnessMeter,
        truePeakDetector: TruePeakDetector? = nil,
        timecode: String? = nil
    ) {
        let now = Date()

        // Integrated loudness (EBU R128)
        if let integrated = loudnessMeter.integratedLKFS {
            let low = integratedTargetLKFS - integratedToleranceLU
            let high = integratedTargetLKFS + integratedToleranceLU
            if integrated < low || integrated > high {
                lock.lock()
                let last = lastIntegratedExceedanceTime
                let allow = last == nil || now.timeIntervalSince(last!) >= eventCooldownSeconds
                if allow { lastIntegratedExceedanceTime = now }
                lock.unlock()
                if allow {
                    let direction = integrated > high ? "above" : "below"
                    let severity: QCEventSeverity = abs(integrated - integratedTargetLKFS) > 2 ? .error : .warning
                    let event = QCEvent(
                        kind: .audioLoudnessExceedance,
                        severity: severity,
                        timecode: timecode,
                        channel: "integrated",
                        value: Double(integrated),
                        threshold: Double(integratedTargetLKFS),
                        description: String(format: "Integrated loudness %.1f LUFS is %@ EBU R128 range [%.1f, %.1f] LUFS",
                                          integrated, direction, low, high),
                        timestamp: now
                    )
                    HDRLogger.logQC(event)
                }
            }
        }

        // True peak (EBU R128: max -1 dBTP)
        if let detector = truePeakDetector {
            let levels = detector.currentTruePeakLevels
            for (ch, linearPeak) in levels.enumerated() {
                if linearPeak > maxTruePeakLinear {
                    lock.lock()
                    let last = lastTruePeakOverloadTime
                    let allow = last == nil || now.timeIntervalSince(last!) >= eventCooldownSeconds
                    if allow { lastTruePeakOverloadTime = now }
                    lock.unlock()
                    if allow {
                        let dbTP = 20.0 * log10(Double(max(linearPeak, 1e-10)))
                        let event = QCEvent(
                            kind: .audioPeakOverload,
                            severity: .warning,
                            timecode: timecode,
                            channel: "ch\(ch)",
                            value: dbTP,
                            threshold: Double(Self.defaultMaxTruePeakDBTP),
                            description: String(format: "True peak ch%u %.2f dBTP exceeds EBU R128 limit %.1f dBTP",
                                                ch, dbTP, Self.defaultMaxTruePeakDBTP),
                            timestamp: now
                        )
                        HDRLogger.logQC(event)
                    }
                    break
                }
            }
        }
    }

    /// Resets cooldown state (e.g. when starting a new programme).
    public func resetCooldown() {
        lock.lock()
        lastIntegratedExceedanceTime = nil
        lastTruePeakOverloadTime = nil
        lock.unlock()
    }
}
