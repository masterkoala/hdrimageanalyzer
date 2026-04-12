import Foundation

/// CSV export for QC events (QC-005). Columns: timecode, event_type, severity, channel, value, threshold, description, timestamp.
public enum QCCSVExport {
    /// CSV header row.
    public static let header = "timecode,event_type,severity,channel,value,threshold,description,timestamp"

    /// Export events to a CSV file at the given URL. Overwrites if file exists.
    /// - Parameters:
    ///   - events: QC events to export (e.g. from QCEventBuffer.snapshot()).
    ///   - url: Destination file URL.
    /// - Throws: File system errors when writing.
    public static func export(events: [QCEvent], to url: URL) throws {
        var lines: [String] = [header]
        let formatter = ISO8601DateFormatter()
        for event in events {
            let timecode = event.timecode ?? ""
            let eventType = event.kind.rawValue
            let severity = event.severity.rawValue
            let channel = event.channel ?? ""
            let value = event.value.map { String($0) } ?? ""
            let threshold = event.threshold.map { String($0) } ?? ""
            let description = escapeCSV(event.description)
            let timestamp = formatter.string(from: event.timestamp)
            let row = [timecode, eventType, severity, channel, value, threshold, description, timestamp]
                .map(escapeCSV)
                .joined(separator: ",")
            lines.append(row)
        }
        let content = lines.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Escape a field for CSV: wrap in quotes if it contains comma, quote, or newline; double any internal quotes.
    private static func escapeCSV(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
