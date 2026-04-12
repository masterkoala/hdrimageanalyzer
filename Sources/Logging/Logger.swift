import Foundation
import os.log

/// Structured logging: OSLog + optional file output (roadmap F-003). Single entry point for all modules.
public enum HDRLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.hdranalyzerpro"
    private static var fileURL: URL?
    private static let fileQueue = DispatchQueue(label: "HDRLogger.file")

    /// Call once at startup to enable file logging (optional).
    public static func setLogFile(url: URL?) { fileURL = url }

    public static func log(_ level: OSLogType, category: String, message: String) {
        let log = Logger(subsystem: subsystem, category: category)
        switch level {
        case .debug: log.debug("\(message, privacy: .public)")
        case .info: log.info("\(message, privacy: .public)")
        case .default: log.log("\(message, privacy: .public)")
        case .error: log.error("\(message, privacy: .public)")
        case .fault: log.fault("\(message, privacy: .public)")
        default: log.log("\(message, privacy: .public)")
        }
        if let url = fileURL {
            fileQueue.async {
                let line = "\(ISO8601DateFormatter().string(from: Date())) [\(category)] \(message)\n"
                if let data = line.data(using: .utf8) {
                    try? data.append(to: url)
                }
            }
        }
    }

    public static func debug(category: String, _ message: String) { log(.debug, category: category, message: message) }
    public static func info(category: String, _ message: String) { log(.info, category: category, message: message) }
    public static func warning(category: String, _ message: String) { log(.default, category: category, message: message) }
    public static func error(category: String, _ message: String) { log(.error, category: category, message: message) }

    // Overloads with explicit `message:` label for backward compatibility
    public static func debug(category: String, message: String) { log(.debug, category: category, message: message) }
    public static func info(category: String, message: String) { log(.info, category: category, message: message) }
    public static func warning(category: String, message: String) { log(.default, category: category, message: message) }
    public static func error(category: String, message: String) { log(.error, category: category, message: message) }

    // MARK: - QC event logging (QC-001, QC-004 timecoded)

    /// Log a QC event via structured logging. Severity maps to OSLogType; category is "QC".
    /// If the event has no timecode and TimecodedQCContext has a current frame timecode (DL-008), the event is logged with that timecode for frame-accurate timecoded logging.
    public static func logQC(_ event: QCEvent) {
        let toLog: QCEvent
        if let tc = event.timecode, !tc.isEmpty {
            toLog = event
        } else if let frameTC = TimecodedQCContext.currentFrameTimecode(), !frameTC.isEmpty {
            toLog = QCEvent(
                kind: event.kind,
                severity: event.severity,
                timecode: frameTC,
                channel: event.channel,
                value: event.value,
                threshold: event.threshold,
                description: event.description,
                timestamp: event.timestamp
            )
        } else {
            toLog = event
        }
        let level: OSLogType
        switch toLog.severity {
        case .info: level = .info
        case .warning: level = .default
        case .error: level = .error
        case .critical: level = .fault
        }
        log(level, category: "QC", message: toLog.logMessage)
        QCEventBuffer.append(toLog)
    }

    /// Export session QC events (buffer filled by logQC) to CSV. Columns: timecode, event_type, severity, channel, value, threshold, description, timestamp (QC-005).
    public static func exportSessionQCEventsToCSV(to url: URL) throws {
        try QCCSVExport.export(events: QCEventBuffer.snapshot(), to: url)
    }

    /// Export session QC events (buffer filled by logQC) to XML interchange format (QC-006).
    public static func exportSessionQCEventsToXML(to url: URL) throws {
        try QCXMLExport.export(events: QCEventBuffer.snapshot(), to: url)
    }
}

extension Data {
    fileprivate func append(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let h = try FileHandle(forWritingTo: url)
            h.seekToEndOfFile()
            h.write(self)
            try h.close()
        } else {
            try write(to: url)
        }
    }
}
