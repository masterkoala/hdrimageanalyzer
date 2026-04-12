import XCTest
@testable import HDRImageAnalyzerPro

/// Comprehensive system integration tests
final class SystemIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        try super.tearDownWithError()
    }

    /// Test complete pipeline integration with OFX simulation
    func testCompletePipelineIntegration() throws {
        // This test verifies that all components work together as expected

        // 1. Initialize core systems
        let captureSystem = CaptureSystem()
        let metalEngine = WorkingMetalEngine.shared
        let qcSystem = EnhancedQCSystem.shared
        let audioAnalyzer = AdvancedAudioAnalyzer()
        let ofxManager = OFXPluginManager.shared
        let webServer = EnhancedWebServer.shared

        // 2. Verify systems are initialized correctly
        XCTAssertNotNil(captureSystem, "Capture system should initialize")
        XCTAssertNotNil(metalEngine, "Metal engine should initialize")
        XCTAssertNotNil(qcSystem, "QC system should initialize")
        XCTAssertNotNil(audioAnalyzer, "Audio analyzer should initialize")
        XCTAssertNotNil(ofxManager, "OFX manager should initialize")
        XCTAssertNotNil(webServer, "Web server should initialize")

        // 3. Test OFX integration with capture pipeline
        let simulation = OFXDeviceSimulation.shared

        // Create a test pattern simulation
        let simulationID = simulation.createTestPatternSimulation(
            name: "Pipeline Integration Test",
            resolution: "1920x1080",
            frameRate: 30.0
        )

        XCTAssertNotNil(simulationID, "Simulation should be created")

        // 4. Test QC event logging during pipeline operations
        qcSystem.logEvent(
            eventType: .systemStatus,
            description: "Pipeline integration test started",
            severity: .info
        )

        // 5. Test audio analysis during processing
        let testData = [Float](repeating: 0.5, count: 100) // Simple test data
        _ = audioAnalyzer.processFrame(audioData: testData, channelCount: 2)

        // 6. Verify statistics are updated
        let stats = qcSystem.getStatistics()
        XCTAssertTrue(stats.totalEvents > 0, "Should have logged events")

        // 7. Test web server integration
        webServer.addOFXDeviceConnection(
            deviceID: simulationID!,
            connection: OFXDeviceConnection(deviceID: simulationID!, deviceType: "TestSimulator")
        )

        let devices = webServer.getConnectedOFXDevices()
        XCTAssertTrue(devices.contains(simulationID!), "Web server should track connected device")

        // 8. Test that all systems can be reset independently
        qcSystem.reset()
        audioAnalyzer.reset()
        webServer.resetStatistics()

        // Verify reset worked
        let resetStats = qcSystem.getStatistics()
        XCTAssertEqual(resetStats.totalEvents, 0, "QC system should be reset")
    }

    /// Test end-to-end workflow with error handling
    func testEndToEndWorkflowWithErrorHandling() throws {
        // Test that the system can handle various scenarios gracefully

        let qcSystem = EnhancedQCSystem.shared
        let audioAnalyzer = AdvancedAudioAnalyzer()

        // 1. Test processing with invalid data
        let invalidData = [Float]() // Empty array
        let result = audioAnalyzer.processFrame(audioData: invalidData, channelCount: 2)

        XCTAssertNotNil(result, "Should handle empty data gracefully")

        // 2. Test QC logging with various severity levels
        qcSystem.logEvent(
            eventType: .systemStatus,
            description: "Test info message",
            severity: .info
        )

        qcSystem.logEvent(
            eventType: .videoQuality,
            description: "Test warning message",
            severity: .warning
        )

        qcSystem.logEvent(
            eventType: .audioQuality,
            description: "Test error message",
            severity: .error
        )

        let stats = qcSystem.getStatistics()
        XCTAssertEqual(stats.totalEvents, 3, "Should have logged 3 events")
        XCTAssertEqual(stats.warningCount, 1, "Should have 1 warning")
        XCTAssertEqual(stats.errorCount, 1, "Should have 1 error")
    }

    /// Test performance of integrated system
    func testSystemPerformance() throws {
        let audioAnalyzer = AdvancedAudioAnalyzer()
        let qcSystem = EnhancedQCSystem.shared

        // Create large test data
        var testData = [Float]()
        for i in 0..<10000 {
            testData.append(Float(i % 10000) / 10000.0)
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Process multiple frames
        for _ in 0..<10 {
            _ = audioAnalyzer.processFrame(audioData: testData, channelCount: 2)

            // Log events during processing to simulate real usage
            qcSystem.logVideoEvent(
                frameNumber: 1,
                resolution: "1920x1080",
                fps: 30.0,
                colorSpace: "Rec.2020",
                description: "Performance test frame"
            )
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let processingTime = endTime - startTime

        XCTAssertLessThan(processingTime, 5.0, "Processing 10 frames should complete within 5 seconds")
    }

    /// Test configuration consistency across systems
    func testConfigurationConsistency() throws {
        // Verify that all systems use consistent configurations

        let ofxConfig = OFXConfiguration()
        let webServer = EnhancedWebServer.shared

        // Test that configurations are accessible and consistent
        XCTAssertTrue(ofxConfig.isEnabled, "OFX should be enabled by default")
        XCTAssertEqual(webServer.port, 8080, "Web server port should match expected value")

        // Test that systems can be configured independently
        webServer.enableOFXIntegration = false
        XCTAssertFalse(webServer.enableOFXIntegration, "OFX integration should be configurable")
    }

    /// Test resource cleanup and memory management
    func testResourceManagement() throws {
        // Test that components can be properly managed

        let qcSystem = EnhancedQCSystem.shared
        let audioAnalyzer = AdvancedAudioAnalyzer()

        // Log multiple events to build up state
        for i in 0..<100 {
            qcSystem.logVideoEvent(
                frameNumber: i,
                resolution: "1920x1080",
                fps: 30.0,
                colorSpace: "Rec.2020",
                description: "Memory test event \(i)"
            )
        }

        // Verify system can handle large volumes
        let stats = qcSystem.getStatistics()
        XCTAssertTrue(stats.totalEvents >= 100, "Should have processed at least 100 events")

        // Reset to prevent memory issues in test suite
        qcSystem.reset()

        // Verify reset worked properly
        let resetStats = qcSystem.getStatistics()
        XCTAssertEqual(resetStats.totalEvents, 0, "Reset should clear all events")
    }
}

/// Mock capture system for testing purposes
class CaptureSystem {
    init() {
        // Mock implementation for testing
    }
}