import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreText)
import CoreText
#endif

/// PDF QC report generator with summary statistics (QC-007).
/// Builds on QC-004 timecoded events; uses same event set as CSV/XML export.
public enum QCPDFReport {

    /// Export QC events to a PDF report at the given URL. Overwrites if file exists.
    /// Report includes: title, generated date, summary statistics (total, by severity, by event type, time range), and event table.
    /// - Parameters:
    ///   - events: QC events to export (e.g. from QCEventBuffer.snapshot()).
    ///   - url: Destination file URL.
    /// - Throws: File system or PDF generation errors.
    public static func export(events: [QCEvent], to url: URL) throws {
        let summary = SummaryStatistics(events: events)
        let data = try renderPDF(events: events, summary: summary)
        try data.write(to: url)
    }

    // MARK: - Summary statistics

    public struct SummaryStatistics {
        public let totalEvents: Int
        public let bySeverity: [QCEventSeverity: Int]
        public let byKind: [QCEventKind: Int]
        public let firstTimecode: String?
        public let lastTimecode: String?
        public let firstTimestamp: Date?
        public let lastTimestamp: Date?

        public init(events: [QCEvent]) {
            totalEvents = events.count
            var sev: [QCEventSeverity: Int] = [:]
            for s in QCEventSeverity.allCases { sev[s] = 0 }
            for e in events { sev[e.severity, default: 0] += 1 }
            bySeverity = sev

            var kind: [QCEventKind: Int] = [:]
            for k in QCEventKind.allCases { kind[k] = 0 }
            for e in events { kind[e.kind, default: 0] += 1 }
            byKind = kind

            let withTC = events.compactMap { $0.timecode }.filter { !$0.isEmpty }
            firstTimecode = withTC.first
            lastTimecode = withTC.last
            firstTimestamp = events.map(\.timestamp).min()
            lastTimestamp = events.map(\.timestamp).max()
        }
    }

    // MARK: - PDF rendering (Core Graphics + Core Text)

    private static let pageWidth: CGFloat = 612
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 36
    private static let titleFontSize: CGFloat = 18
    private static let headingFontSize: CGFloat = 12
    private static let bodyFontSize: CGFloat = 10
    private static let tableRowHeight: CGFloat = 14
    private static let maxTableRowsPerPage: Int = 35

    private static func renderPDF(events: [QCEvent], summary: SummaryStatistics) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            throw NSError(domain: "QCPDFReport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PDF data consumer"])
        }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "QCPDFReport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create PDF context"])
        }

        // Page 1: title, date, summary
        ctx.beginPDFPage(nil)
        var y = pageHeight - margin
        y = drawTitle(ctx: ctx, y: y)
        y -= 8
        y = drawGeneratedDate(ctx: ctx, y: y)
        y -= 20
        y = drawSummarySection(ctx: ctx, y: y, summary: summary)
        ctx.endPDFPage()

        // Event table (paginated)
        let tableRows = events
        var rowIndex = 0
        while rowIndex < tableRows.count {
            ctx.beginPDFPage(nil)
            var pageY = pageHeight - margin
            pageY = drawTableHeader(ctx: ctx, y: pageY)
            let endIndex = min(rowIndex + maxTableRowsPerPage, tableRows.count)
            for i in rowIndex..<endIndex {
                pageY = drawTableRow(ctx: ctx, y: pageY, event: tableRows[i])
            }
            rowIndex = endIndex
            ctx.endPDFPage()
        }

        ctx.closePDF()
        return data as Data
    }

    private static func drawTitle(ctx: CGContext, y: CGFloat) -> CGFloat {
        _ = drawText(ctx: ctx, text: "HDR Image Analyzer Pro — QC Report", x: margin, y: y, fontSize: titleFontSize, bold: true)
        return y - titleFontSize - 4
    }

    private static func drawGeneratedDate(ctx: CGContext, y: CGFloat) -> CGFloat {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateStr = "Generated: \(formatter.string(from: Date()))"
        _ = drawText(ctx: ctx, text: dateStr, x: margin, y: y, fontSize: bodyFontSize, bold: false)
        return y - bodyFontSize - 4
    }

    private static func drawSummarySection(ctx: CGContext, y: CGFloat, summary: SummaryStatistics) -> CGFloat {
        var yy = drawText(ctx: ctx, text: "Summary", x: margin, y: y, fontSize: headingFontSize, bold: true)
        yy -= 6
        yy = drawText(ctx: ctx, text: "Total events: \(summary.totalEvents)", x: margin, y: yy, fontSize: bodyFontSize, bold: false)
        yy -= bodyFontSize + 2
        yy = drawText(ctx: ctx, text: "By severity:", x: margin, y: yy, fontSize: bodyFontSize, bold: true)
        yy -= bodyFontSize + 2
        for sev in QCEventSeverity.allCases {
            let count = summary.bySeverity[sev] ?? 0
            yy = drawText(ctx: ctx, text: "  \(sev.rawValue): \(count)", x: margin, y: yy, fontSize: bodyFontSize, bold: false)
            yy -= bodyFontSize + 1
        }
        yy -= 4
        yy = drawText(ctx: ctx, text: "By event type (non-zero):", x: margin, y: yy, fontSize: bodyFontSize, bold: true)
        yy -= bodyFontSize + 2
        for kind in QCEventKind.allCases {
            let count = summary.byKind[kind] ?? 0
            if count > 0 {
                yy = drawText(ctx: ctx, text: "  \(kind.displayName): \(count)", x: margin, y: yy, fontSize: bodyFontSize, bold: false)
                yy -= bodyFontSize + 1
            }
        }
        yy -= 4
        if let first = summary.firstTimecode ?? summary.firstTimestamp.map({ ISO8601DateFormatter().string(from: $0) }) {
            yy = drawText(ctx: ctx, text: "First: \(first)", x: margin, y: yy, fontSize: bodyFontSize, bold: false)
            yy -= bodyFontSize + 1
        }
        if let last = summary.lastTimecode ?? summary.lastTimestamp.map({ ISO8601DateFormatter().string(from: $0) }) {
            yy = drawText(ctx: ctx, text: "Last: \(last)", x: margin, y: yy, fontSize: bodyFontSize, bold: false)
            yy -= bodyFontSize + 1
        }
        return yy
    }

    private static func drawTableHeader(ctx: CGContext, y: CGFloat) -> CGFloat {
        var yy = y
        yy = drawText(ctx: ctx, text: "Timecode", x: margin, y: yy, fontSize: bodyFontSize, bold: true)
        _ = drawText(ctx: ctx, text: "Type", x: margin + 80, y: yy, fontSize: bodyFontSize, bold: true)
        _ = drawText(ctx: ctx, text: "Severity", x: margin + 200, y: yy, fontSize: bodyFontSize, bold: true)
        _ = drawText(ctx: ctx, text: "Description", x: margin + 280, y: yy, fontSize: bodyFontSize, bold: true)
        return yy - tableRowHeight - 2
    }

    private static func drawTableRow(ctx: CGContext, y: CGFloat, event: QCEvent) -> CGFloat {
        let tc = event.timecode ?? "—"
        let typeStr = event.kind.displayName
        let sevStr = event.severity.rawValue
        let desc = event.description
        let yy = y
        _ = drawText(ctx: ctx, text: tc, x: margin, y: yy, fontSize: bodyFontSize, bold: false)
        _ = drawText(ctx: ctx, text: typeStr, x: margin + 80, y: yy, fontSize: bodyFontSize, bold: false)
        _ = drawText(ctx: ctx, text: sevStr, x: margin + 200, y: yy, fontSize: bodyFontSize, bold: false)
        drawTextInBox(ctx: ctx, text: desc, x: margin + 280, y: yy, maxWidth: pageWidth - margin - 300, fontSize: bodyFontSize)
        return yy - tableRowHeight
    }

    private static func drawText(ctx: CGContext, text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat, bold: Bool) -> CGFloat {
        #if canImport(CoreText)
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true
        ]
        let attrString = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let frameSetter = CTFramesetterCreateWithAttributedString(attrString)
        let path = CGPath(rect: CGRect(x: x, y: y - fontSize, width: pageWidth - 2 * margin, height: fontSize + 4), transform: nil)
        let frame = CTFramesetterCreateFrame(frameSetter, CFRange(location: 0, length: 0), path, nil)
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: x, y: y)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
        #endif
        return y - fontSize
    }

    private static func drawTextInBox(ctx: CGContext, text: String, x: CGFloat, y: CGFloat, maxWidth: CGFloat, fontSize: CGFloat) {
        #if canImport(CoreText)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true
        ]
        let attrString = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let frameSetter = CTFramesetterCreateWithAttributedString(attrString)
        let path = CGPath(rect: CGRect(x: x, y: y - fontSize, width: maxWidth, height: tableRowHeight + 4), transform: nil)
        let frame = CTFramesetterCreateFrame(frameSetter, CFRange(location: 0, length: 0), path, nil)
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: x, y: y)
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
        #endif
    }
}
