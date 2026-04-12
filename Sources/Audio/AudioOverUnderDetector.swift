import Foundation
import Logging

/// Audio over/under level detection with QC logging (AU-012).
/// Uses peak levels from AU-002 PeakLevelMeter; detects when level goes over a high threshold (over)
/// or under a low threshold (under) and logs timecoded QC events via HDRLogger.logQC.
///
/// Typical use: call `check(peakLevels:timecode:)` periodically (e.g. after PeakLevelMeter.process(from:))
/// with `peakMeter.currentPeakLevels`. Over = level above threshold (e.g. near clipping). Under = level below threshold (e.g. silence).
public final class AudioOverUnderDetector {
    /// Default over threshold: peak above this (linear) is considered "over" (-1 dB ≈ 0.891).
    public static let defaultOverThresholdLinear: Float = 0.89125
    /// Default under threshold: peak below this (linear) is considered "under" (-60 dB ≈ 0.001).
    public static let defaultUnderThresholdLinear: Float = 0.001

    private let overThresholdLinear: Float
    private let underThresholdLinear: Float
    private let eventCooldownSeconds: TimeInterval
    private var lastOverTime: Date?
    private var lastUnderTime: Date?
    private let lock = NSLock()

    /// - Parameters:
    ///   - overThresholdLinear: Peak above this (linear 0...1) triggers "over" event (default -1 dB).
    ///   - underThresholdLinear: Peak below this (linear) triggers "under" event (default -60 dB).
    ///   - eventCooldownSeconds: Min seconds between same-kind events (default 2).
    public init(
        overThresholdLinear: Float = AudioOverUnderDetector.defaultOverThresholdLinear,
        underThresholdLinear: Float = AudioOverUnderDetector.defaultUnderThresholdLinear,
        eventCooldownSeconds: TimeInterval = 2.0
    ) {
        self.overThresholdLinear = overThresholdLinear
        self.underThresholdLinear = underThresholdLinear
        self.eventCooldownSeconds = eventCooldownSeconds
    }

    /// Check peak levels and log QC events when over or under thresholds (with cooldown).
    /// Call from the same thread that runs the meters (e.g. after PeakLevelMeter.process(from:)).
    /// - Parameters:
    ///   - peakLevels: Current peak level per channel in linear scale (e.g. from PeakLevelMeter.currentPeakLevels).
    ///   - timecode: Optional timecode for emitted events.
    public func check(peakLevels: [Float], timecode: String? = nil) {
        guard !peakLevels.isEmpty else { return }
        let now = Date()

        // Over: any channel above over threshold
        let overChannels = peakLevels.enumerated().filter { $0.element > overThresholdLinear }.map { $0.offset }
        if let ch = overChannels.first {
            lock.lock()
            let last = lastOverTime
            let allow = last == nil || now.timeIntervalSince(last!) >= eventCooldownSeconds
            if allow { lastOverTime = now }
            lock.unlock()
            if allow {
                let linear = peakLevels[ch]
                let db = 20.0 * log10(Double(max(linear, 1e-10)))
                let thresholdDB = 20.0 * log10(Double(overThresholdLinear))
                let chList = overChannels.map { "ch\($0)" }.joined(separator: ",")
                let event = QCEvent(
                    kind: .audioPeakOverload,
                    severity: .warning,
                    timecode: timecode,
                    channel: chList,
                    value: db,
                    threshold: thresholdDB,
                    description: String(format: "Peak level %@ %.2f dB exceeds over threshold %.1f dB",
                                       chList, db, thresholdDB),
                    timestamp: now
                )
                HDRLogger.logQC(event)
            }
        }

        // Under: any channel below under threshold
        let underChannels = peakLevels.enumerated().filter { $0.element < underThresholdLinear }.map { $0.offset }
        if let ch = underChannels.first {
            lock.lock()
            let last = lastUnderTime
            let allow = last == nil || now.timeIntervalSince(last!) >= eventCooldownSeconds
            if allow { lastUnderTime = now }
            lock.unlock()
            if allow {
                let linear = peakLevels[ch]
                let db = 20.0 * log10(Double(max(linear, 1e-10)))
                let thresholdDB = 20.0 * log10(Double(max(underThresholdLinear, 1e-10)))
                let chList = underChannels.map { "ch\($0)" }.joined(separator: ",")
                let event = QCEvent(
                    kind: .audioLevelUnder,
                    severity: .warning,
                    timecode: timecode,
                    channel: chList,
                    value: db,
                    threshold: thresholdDB,
                    description: String(format: "Peak level %@ %.2f dB below under threshold %.1f dB",
                                       chList, db, thresholdDB),
                    timestamp: now
                )
                HDRLogger.logQC(event)
            }
        }
    }

    /// Resets cooldown state (e.g. when starting a new programme).
    public func resetCooldown() {
        lock.lock()
        lastOverTime = nil
        lastUnderTime = nil
        lock.unlock()
    }
}
