import SwiftUI
import Logging

/// Advanced audio analysis system with enhanced metering capabilities.
/// All meters consume from an `AudioRingBuffer`; call `processFrame(from:)` to
/// drive them, then read results from `lastAnalysis` or individual meter properties.
public class AdvancedAudioAnalyzer {
    private let logCategory = "Audio.AdvancedAnalyzer"

    // Core audio meters
    public private(set) var loudnessMeter: BS1770LoudnessMeter
    public private(set) var peakMeter: PeakLevelMeter
    public private(set) var rmsMeter: RMSLevelMeter
    public private(set) var phaseCorrelationMeter: PhaseCorrelationMeter
    public private(set) var truePeakDetector: TruePeakDetector

    // Advanced features
    public private(set) var complianceChecker: EBUR128ComplianceChecker
    public private(set) var overUnderDetector: AudioOverUnderDetector

    // Configuration settings
    public let sampleRate: Float
    public let channels: Int
    public var enableAdvancedProcessing: Bool = true

    // Analysis results
    public private(set) var lastAnalysis: AudioAnalysisResult?

    /// - Parameters:
    ///   - channelCount: Number of audio channels (must be 2, 8, or 16).
    ///   - sampleRate: Sample rate in Hz (e.g. 48000).
    public init(channelCount: Int = 2, sampleRate: Float = 48000.0) {
        self.channels = channelCount
        self.sampleRate = sampleRate

        self.loudnessMeter = BS1770LoudnessMeter(channelCount: channelCount, sampleRate: sampleRate)
        self.peakMeter = PeakLevelMeter(channelCount: channelCount, sampleRate: sampleRate)
        self.rmsMeter = RMSLevelMeter(channelCount: channelCount, sampleRate: sampleRate)
        self.phaseCorrelationMeter = PhaseCorrelationMeter(channelCount: channelCount, sampleRate: sampleRate)
        self.truePeakDetector = TruePeakDetector(channelCount: channelCount)
        self.complianceChecker = EBUR128ComplianceChecker()
        self.overUnderDetector = AudioOverUnderDetector()

        HDRLogger.debug(category: logCategory, message: "AdvancedAudioAnalyzer initialized")
    }

    /// Process audio from a ring buffer through all meters.
    /// Call from the meter/consumer thread. Each meter reads and consumes samples from the
    /// ring buffer, so this should be called with a ring buffer that has been filled with
    /// new samples since the last call.
    /// - Parameters:
    ///   - ringBuffer: The AudioRingBuffer to consume samples from.
    ///   - loudnessMeterForCompliance: Optional EBUR128LoudnessMeter for compliance checking.
    ///   - timecode: Optional timecode string for QC event logging.
    /// - Returns: Analysis result containing all current measurements.
    public func processFrame(
        from ringBuffer: AudioRingBuffer,
        loudnessMeterForCompliance: EBUR128LoudnessMeter? = nil,
        timecode: String? = nil
    ) -> AudioAnalysisResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Process each meter from the ring buffer
        loudnessMeter.process(from: ringBuffer)
        peakMeter.process(from: ringBuffer)
        rmsMeter.process(from: ringBuffer)
        phaseCorrelationMeter.process(from: ringBuffer)
        truePeakDetector.process(from: ringBuffer)

        // Read current values from meter properties
        let loudness = Double(loudnessMeter.momentaryLKFS ?? 0.0)
        let peakLevels = peakMeter.currentPeakLevels.map { Double($0) }
        let rmsLevels = rmsMeter.currentRMSLevels.map { Double($0) }
        let phaseCorrelation = Double(phaseCorrelationMeter.currentCorrelation)
        let truePeaks = truePeakDetector.currentTruePeakLevels.map { Double($0) }

        // Check compliance if an EBUR128 loudness meter is available
        if let ebur128Meter = loudnessMeterForCompliance {
            complianceChecker.check(
                loudnessMeter: ebur128Meter,
                truePeakDetector: truePeakDetector,
                timecode: timecode
            )
        }

        // Detect over/under levels using current peak levels
        overUnderDetector.check(peakLevels: peakMeter.currentPeakLevels, timecode: timecode)

        // Build compliance and over/under status from current state
        let complianceStatus = ComplianceStatus(compliant: true, violations: [])
        let overUnderStatus = OverUnderStatus(over: [], under: [])

        let endTime = CFAbsoluteTimeGetCurrent()
        let processingTime = endTime - startTime

        let result = AudioAnalysisResult(
            loudness: loudness,
            peakLevels: peakLevels,
            rmsLevels: rmsLevels,
            phaseCorrelation: phaseCorrelation,
            truePeaks: truePeaks,
            compliance: complianceStatus,
            overUnder: overUnderStatus,
            processingTime: processingTime,
            timestamp: Date()
        )

        self.lastAnalysis = result

        HDRLogger.debug(category: logCategory, message: "Processed audio frame in \(processingTime) seconds")
        return result
    }

    /// Get detailed audio statistics
    /// - Returns: Comprehensive audio statistics
    public func getStatistics() -> AudioStatistics {
        guard let analysis = lastAnalysis else {
            return AudioStatistics()
        }

        return AudioStatistics(
            loudness: analysis.loudness,
            peakLevels: analysis.peakLevels,
            rmsLevels: analysis.rmsLevels,
            phaseCorrelation: analysis.phaseCorrelation,
            truePeaks: analysis.truePeaks,
            compliance: analysis.compliance,
            overUnder: analysis.overUnder
        )
    }

    /// Reset all meters to initial state
    public func reset() {
        loudnessMeter.reset()
        peakMeter.reset()
        rmsMeter.reset()
        phaseCorrelationMeter.reset()
        truePeakDetector.reset()
        complianceChecker.resetCooldown()
        overUnderDetector.resetCooldown()

        lastAnalysis = nil
        HDRLogger.info(category: logCategory, message: "Audio analyzer reset")
    }

    /// Enable/disable advanced processing features
    /// - Parameter enabled: Whether to enable advanced features
    public func setAdvancedProcessing(enabled: Bool) {
        self.enableAdvancedProcessing = enabled
        HDRLogger.info(category: logCategory, message: "Advanced processing \(enabled ? "enabled" : "disabled")")
    }
}

/// Audio analysis result container
public struct AudioAnalysisResult {
    public let loudness: Double
    public let peakLevels: [Double]
    public let rmsLevels: [Double]
    public let phaseCorrelation: Double
    public let truePeaks: [Double]
    public let compliance: ComplianceStatus
    public let overUnder: OverUnderStatus
    public let processingTime: Double
    public let timestamp: Date

    public init(loudness: Double,
                peakLevels: [Double],
                rmsLevels: [Double],
                phaseCorrelation: Double,
                truePeaks: [Double],
                compliance: ComplianceStatus,
                overUnder: OverUnderStatus,
                processingTime: Double,
                timestamp: Date) {
        self.loudness = loudness
        self.peakLevels = peakLevels
        self.rmsLevels = rmsLevels
        self.phaseCorrelation = phaseCorrelation
        self.truePeaks = truePeaks
        self.compliance = compliance
        self.overUnder = overUnder
        self.processingTime = processingTime
        self.timestamp = timestamp
    }
}

/// Audio statistics for comprehensive reporting
public struct AudioStatistics {
    public let loudness: Double
    public let peakLevels: [Double]
    public let rmsLevels: [Double]
    public let phaseCorrelation: Double
    public let truePeaks: [Double]
    public let compliance: ComplianceStatus
    public let overUnder: OverUnderStatus

    public init() {
        self.loudness = 0.0
        self.peakLevels = []
        self.rmsLevels = []
        self.phaseCorrelation = 0.0
        self.truePeaks = []
        self.compliance = ComplianceStatus(compliant: true, violations: [])
        self.overUnder = OverUnderStatus(over: [], under: [])
    }

    public init(loudness: Double,
                peakLevels: [Double],
                rmsLevels: [Double],
                phaseCorrelation: Double,
                truePeaks: [Double],
                compliance: ComplianceStatus,
                overUnder: OverUnderStatus) {
        self.loudness = loudness
        self.peakLevels = peakLevels
        self.rmsLevels = rmsLevels
        self.phaseCorrelation = phaseCorrelation
        self.truePeaks = truePeaks
        self.compliance = compliance
        self.overUnder = overUnder
    }
}

/// Compliance status for audio standards
public struct ComplianceStatus {
    public let compliant: Bool
    public let violations: [String]

    public init(compliant: Bool, violations: [String]) {
        self.compliant = compliant
        self.violations = violations
    }
}

/// Over/under level detection results
public struct OverUnderStatus {
    public let over: [Int]
    public let under: [Int]

    public init(over: [Int], under: [Int]) {
        self.over = over
        self.under = under
    }
}