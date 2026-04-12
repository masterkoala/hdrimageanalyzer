import Foundation
import os.log

/// Enhanced Quality Control system with advanced reporting capabilities
public class EnhancedQCSystem {
    public static let shared = EnhancedQCSystem()

    private let logCategory = "Logging.EnhancedQC"

    // Core QC components
    public private(set) var signalMonitor: SignalContinuityMonitor

    // Configuration
    public var maxEvents: Int = 10000
    public var autoSaveInterval: TimeInterval = 300.0 // 5 minutes
    public var enableAdvancedLogging: Bool = true

    // Statistics tracking
    public private(set) var eventStatistics: QCEventStatistics = QCEventStatistics()

    private var autoSaveTimer: Timer?
    private var lastAutoSaveTime: Date = Date()

    private init() {
        self.signalMonitor = SignalContinuityMonitor()

        startAutoSaveTimer()
        HDRLogger.debug(category: logCategory, "EnhancedQCSystem initialized")
    }

    /// Log a quality control event
    /// - Parameters:
    ///   - eventKind: Kind of QC event
    ///   - description: Description of the event
    ///   - severity: Severity level (default: info)
    ///   - timecode: Optional timecode string
    ///   - channel: Optional channel identifier
    ///   - value: Optional measured value
    ///   - threshold: Optional threshold value
    public func logEvent(eventKind: QCEventKind,
                        description: String,
                        severity: QCEventSeverity = .info,
                        timecode: String? = nil,
                        channel: String? = nil,
                        value: Double? = nil,
                        threshold: Double? = nil) {
        let event = QCEvent(
            kind: eventKind,
            severity: severity,
            timecode: timecode,
            channel: channel,
            value: value,
            threshold: threshold,
            description: description
        )

        HDRLogger.logQC(event)
        updateStatistics(eventKind: eventKind, severity: severity)
    }

    /// Log a video quality event with frame information
    /// - Parameters:
    ///   - frameNumber: Frame number in sequence
    ///   - resolution: Video resolution
    ///   - fps: Frames per second
    ///   - colorSpace: Color space of the video
    ///   - description: Description of the event
    public func logVideoEvent(frameNumber: Int,
                             resolution: String,
                             fps: Double,
                             colorSpace: String,
                             description: String) {
        let fullDescription = "\(description) [frame=\(frameNumber) resolution=\(resolution) fps=\(fps) colorSpace=\(colorSpace)]"

        logEvent(
            eventKind: .gamutViolation,
            description: fullDescription,
            severity: .info
        )
    }

    /// Log an audio quality event
    /// - Parameters:
    ///   - channelCount: Number of audio channels
    ///   - sampleRate: Audio sample rate
    ///   - loudness: Loudness measurement (LUFS)
    ///   - peakLevel: Peak level measurement (dBFS)
    ///   - description: Description of the event
    public func logAudioEvent(channelCount: Int,
                             sampleRate: Double,
                             loudness: Double,
                             peakLevel: Double,
                             description: String) {
        let fullDescription = "\(description) [channels=\(channelCount) sampleRate=\(sampleRate) loudness=\(loudness) peakLevel=\(peakLevel)]"

        logEvent(
            eventKind: .audioLoudnessExceedance,
            description: fullDescription,
            severity: .info,
            channel: "\(channelCount)ch",
            value: peakLevel
        )
    }

    /// Export QC data to CSV format
    /// - Parameter url: URL where to save the CSV file
    /// - Returns: Boolean indicating success or failure
    public func exportToCSV(url: URL) -> Bool {
        do {
            try QCCSVExport.export(events: QCEventBuffer.snapshot(), to: url)
            HDRLogger.info(category: logCategory, "Exported QC data to CSV: \(url.path)")
            return true
        } catch {
            HDRLogger.error(category: logCategory, "Failed to export to CSV: \(error)")
            return false
        }
    }

    /// Export QC data to XML format
    /// - Parameter url: URL where to save the XML file
    /// - Returns: Boolean indicating success or failure
    public func exportToXML(url: URL) -> Bool {
        do {
            try QCXMLExport.export(events: QCEventBuffer.snapshot(), to: url)
            HDRLogger.info(category: logCategory, "Exported QC data to XML: \(url.path)")
            return true
        } catch {
            HDRLogger.error(category: logCategory, "Failed to export to XML: \(error)")
            return false
        }
    }

    /// Generate PDF report of QC events
    /// - Parameter url: URL where to save the PDF file
    /// - Returns: Boolean indicating success or failure
    public func generatePDFReport(url: URL) -> Bool {
        do {
            try QCPDFReport.export(events: QCEventBuffer.snapshot(), to: url)
            HDRLogger.info(category: logCategory, "Generated QC PDF report: \(url.path)")
            return true
        } catch {
            HDRLogger.error(category: logCategory, "Failed to generate PDF report: \(error)")
            return false
        }
    }

    /// Get current QC statistics
    /// - Returns: QCEventStatistics object with current metrics
    public func getStatistics() -> QCEventStatistics {
        return eventStatistics
    }

    /// Reset all QC data and statistics
    public func reset() {
        QCEventBuffer.clear()
        signalMonitor.reset()
        eventStatistics = QCEventStatistics()
        lastAutoSaveTime = Date()
        HDRLogger.info(category: logCategory, "QC system reset")
    }

    /// Enable/disable advanced logging features
    /// - Parameter enabled: Whether to enable advanced features
    public func setAdvancedLogging(enabled: Bool) {
        self.enableAdvancedLogging = enabled
        HDRLogger.info(category: logCategory, "Advanced logging \(enabled ? "enabled" : "disabled")")
    }

    private func updateStatistics(eventKind: QCEventKind, severity: QCEventSeverity) {
        eventStatistics.totalEvents += 1

        switch eventKind {
        case .gamutViolation, .luminanceExceedance, .luminanceBelow,
             .blackClipping, .whiteClipping, .freezeFrame, .blackFrame:
            eventStatistics.videoEvents += 1
        case .audioPeakOverload, .audioLoudnessExceedance,
             .audioLevelUnder, .audioPhaseError:
            eventStatistics.audioEvents += 1
        case .signalLoss, .formatChange, .droppedFrame,
             .timecodeBreak, .deviceChange:
            eventStatistics.systemEvents += 1
        case .metadataError, .dolbyVisionRpuError, .hdr10MetadataError, .other:
            eventStatistics.userEvents += 1
        }

        switch severity {
        case .error, .critical:
            eventStatistics.errorCount += 1
        case .warning:
            eventStatistics.warningCount += 1
        case .info:
            break
        }
    }

    private func startAutoSaveTimer() {
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: autoSaveInterval, repeats: true) { _ in
            self.autoSave()
        }
    }

    private func autoSave() {
        let now = Date()
        if now.timeIntervalSince(lastAutoSaveTime) >= autoSaveInterval {
            // Auto-save logic could be implemented here
            lastAutoSaveTime = now
            HDRLogger.debug(category: logCategory, "Auto-save triggered")
        }
    }
}

/// Enhanced QC event statistics with more detailed metrics
public struct QCEventStatistics {
    public var totalEvents: Int = 0
    public var videoEvents: Int = 0
    public var audioEvents: Int = 0
    public var systemEvents: Int = 0
    public var userEvents: Int = 0
    public var errorCount: Int = 0
    public var warningCount: Int = 0

    public init() {}

    /// Get success rate (percentage of non-error events)
    public var successRate: Double {
        guard totalEvents > 0 else { return 100.0 }
        return Double(totalEvents - errorCount) / Double(totalEvents) * 100.0
    }

    /// Get error percentage
    public var errorPercentage: Double {
        guard totalEvents > 0 else { return 0.0 }
        return Double(errorCount) / Double(totalEvents) * 100.0
    }
}