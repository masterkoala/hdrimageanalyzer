import Foundation

/// XML export for QC events (QC-006). Interchange format: root qc_events, each event as event with child elements.
public enum QCXMLExport {
    /// Root element name for the QC events document.
    public static let rootElementName = "qc_events"

    /// Export events to an XML file at the given URL. Overwrites if file exists.
    /// - Parameters:
    ///   - events: QC events to export (e.g. from QCEventBuffer.snapshot()).
    ///   - url: Destination file URL.
    /// - Throws: File system errors when writing.
    public static func export(events: [QCEvent], to url: URL) throws {
        let formatter = ISO8601DateFormatter()
        var parts: [String] = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<\(rootElementName)>"
        ]
        for event in events {
            let timecode = event.timecode ?? ""
            let eventType = event.kind.rawValue
            let severity = event.severity.rawValue
            let channel = event.channel ?? ""
            let value = event.value.map { String($0) } ?? ""
            let threshold = event.threshold.map { String($0) } ?? ""
            let description = escapeXML(event.description)
            let timestamp = formatter.string(from: event.timestamp)
            parts.append("  <event>")
            parts.append("    <timecode>\(escapeXML(timecode))</timecode>")
            parts.append("    <event_type>\(escapeXML(eventType))</event_type>")
            parts.append("    <severity>\(escapeXML(severity))</severity>")
            parts.append("    <channel>\(escapeXML(channel))</channel>")
            parts.append("    <value>\(escapeXML(value))</value>")
            parts.append("    <threshold>\(escapeXML(threshold))</threshold>")
            parts.append("    <description>\(description)</description>")
            parts.append("    <timestamp>\(escapeXML(timestamp))</timestamp>")
            parts.append("  </event>")
        }
        parts.append("</\(rootElementName)>")
        let content = parts.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Escape text for XML element content: & < > " '
    private static func escapeXML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
