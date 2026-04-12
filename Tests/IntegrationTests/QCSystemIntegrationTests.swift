import XCTest
@testable import HDRImageAnalyzerPro

/// Integration tests for Quality Control system
final class QCSystemIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        try super.tearDownWithError()
    }

    /// Test enhanced QC system initialization
    func testQCSystemInitialization() throws {
        let qcSystem = EnhancedQCSystem.shared

        XCTAssertNotNil(qcSystem, "Enhanced QC System should not be nil")
        XCTAssertEqual(qcSystem.getStatistics().totalEvents, 0, "Initially, no events should be logged")
    }

    /// Test video quality event logging
    func testVideoQualityEventLogging() throws {
        let qcSystem = EnhancedQCSystem.shared

        // Log a video quality event
        qcSystem.logVideoEvent(
            frameNumber: 100,
            resolution: "1920x1080",
            fps: 30.0,
            colorSpace: "Rec.2020",
            description: "Test video quality event"
        )

        let stats = qcSystem.getStatistics()
        XCTAssertTrue(stats.totalEvents > 0, "Should have logged at least one event")
        XCTAssertEqual(stats.videoEvents, 1, "Should have logged one video event")
    }

    /// Test audio quality event logging
    func testAudioQualityEventLogging() throws {
        let qcSystem = EnhancedQCSystem.shared

        // Log an audio quality event
        qcSystem.logAudioEvent(
            channelCount: 2,
            sampleRate: 48000.0,
            loudness: -23.5,
            peakLevel: -3.2,
            description: "Test audio quality event"
        )

        let stats = qcSystem.getStatistics()
        XCTAssertTrue(stats.totalEvents > 0, "Should have logged at least one event")
        XCTAssertEqual(stats.audioEvents, 1, "Should have logged one audio event")
    }

    /// Test export functionality
    func testQCExportFunctionality() throws {
        let qcSystem = EnhancedQCSystem.shared

        // Log some events first
        qcSystem.logVideoEvent(
            frameNumber: 1,
            resolution: "1920x1080",
            fps: 30.0,
            colorSpace: "Rec.2020",
            description: "Test export event 1"
        )

        qcSystem.logAudioEvent(
            channelCount: 2,
            sampleRate: 48000.0,
            loudness: -24.0,
            peakLevel: -2.5,
            description: "Test export event 2"
        )

        // Test CSV export
        let csvExportResult = qcSystem.exportToCSV(filePath: "/tmp/test_export.csv")
        XCTAssertTrue(csvExportResult, "CSV export should succeed")

        // Test XML export
        let xmlExportResult = qcSystem.exportToXML(filePath: "/tmp/test_export.xml")
        XCTAssertTrue(xmlExportResult, "XML export should succeed")

        // Test PDF report generation
        let pdfReportResult = qcSystem.generatePDFReport(filePath: "/tmp/test_report.pdf")
        XCTAssertTrue(pdfReportResult, "PDF report generation should succeed")
    }

    /// Test statistics calculation
    func testQCStatistics() throws {
        let qcSystem = EnhancedQCSystem.shared

        // Log several events
        for i in 0..<5 {
            qcSystem.logVideoEvent(
                frameNumber: i,
                resolution: "1920x1080",
                fps: 30.0,
                colorSpace: "Rec.2020",
                description: "Test event \(i)"
            )
        }

        let stats = qcSystem.getStatistics()

        XCTAssertEqual(stats.totalEvents, 5, "Should have 5 total events")
        XCTAssertEqual(stats.videoEvents, 5, "Should have 5 video events")
        XCTAssertEqual(stats.audioEvents, 0, "Should have 0 audio events")
        XCTAssertEqual(stats.systemEvents, 0, "Should have 0 system events")
        XCTAssertEqual(stats.userEvents, 0, "Should have 0 user events")
    }

    /// Test reset functionality
    func testQCSystemReset() throws {
        let qcSystem = EnhancedQCSystem.shared

        // Log some events
        qcSystem.logVideoEvent(
            frameNumber: 1,
            resolution: "1920x1080",
            fps: 30.0,
            colorSpace: "Rec.2020",
            description: "Pre-reset event"
        )

        let initialStats = qcSystem.getStatistics()
        XCTAssertTrue(initialStats.totalEvents > 0, "Should have events before reset")

        // Reset the system
        qcSystem.reset()

        let resetStats = qcSystem.getStatistics()
        XCTAssertEqual(resetStats.totalEvents, 0, "Should have no events after reset")
        XCTAssertEqual(resetStats.videoEvents, 0, "Should have no video events after reset")
    }
}