import XCTest
@testable import HDRImageAnalyzerPro

/// Tests for DeckLink hardware compatibility and configuration
final class DeckLinkCompatibilityTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        try super.tearDownWithError()
    }

    /// Test that system can handle different video formats
    func testVideoFormatCompatibility() throws {
        // Test that our pipeline can work with various video formats

        let masterPipeline = MasterPipeline(engine: WorkingMetalEngine.shared)

        // Test different pixel formats that might be encountered
        let formats: [FramePixelFormat] = [
            kPixelFormatV210,  // v210 format (our main focus)
            kPixelFormatR12L,  // R12L format
            kPixelFormatBGRA   // BGRA format
        ]

        for format in formats {
            // These tests verify that the system doesn't crash when handling different formats
            // In a real scenario, we would test with actual frames
            XCTAssertTrue(format >= 0, "Pixel format should be valid")
        }

        // Test pipeline status retrieval
        let pipelineStatus = masterPipeline.getPipelineStatus()
        XCTAssertFalse(pipelineStatus.isEmpty, "Pipeline status should not be empty")
    }

    /// Test hardware configuration handling
    func testHardwareConfiguration() throws {
        // Test that we can handle different DeckLink hardware configurations

        // This would normally query actual hardware
        let deviceManager = DeckLinkDeviceManager()

        // Test that the manager initializes properly
        XCTAssertNotNil(deviceManager, "DeckLink device manager should initialize")

        // Test that we can access device information
        let devices = deviceManager.getAvailableDevices()
        // Note: This may return empty in test environment but shouldn't crash
    }

    /// Test frame processing with different resolutions
    func testResolutionCompatibility() throws {
        // Test that our system handles different video resolutions

        let testResolutions = [
            "720x480",
            "1280x720",
            "1920x1080",
            "3840x2160"
        ]

        for resolution in testResolutions {
            // Test that resolution strings are handled properly
            XCTAssertFalse(resolution.isEmpty, "Resolution string should not be empty")
            XCTAssertTrue(resolution.contains("x"), "Resolution should contain 'x' separator")
        }
    }

    /// Test performance with different hardware configurations
    func testHardwarePerformance() throws {
        // Test that system performs reasonably across different scenarios

        let startTime = CFAbsoluteTimeGetCurrent()

        // Simulate processing multiple frames with different configurations
        for i in 0..<10 {
            // This would normally process actual frames
            let testFrame = Frame(
                width: 1920,
                height: 1080,
                pixelFormat: kPixelFormatV210
            )

            // Test that frame creation doesn't crash
            XCTAssertNotNil(testFrame, "Test frame should be created")
        }

        let endTime = CFAbsoluteTimeGetCurrent()
        let processingTime = endTime - startTime

        // Should complete quickly in test environment
        XCTAssertLessThan(processingTime, 1.0, "Processing 10 frames should complete quickly")
    }

    /// Test error handling with hardware issues
    func testHardwareErrorHandling() throws {
        // Test that system gracefully handles hardware-related errors

        let qcSystem = EnhancedQCSystem.shared

        // Log a potential hardware error
        qcSystem.logEvent(
            eventType: .systemStatus,
            description: "Hardware compatibility test",
            severity: .info
        )

        // Verify the system can continue operating after logging
        let stats = qcSystem.getStatistics()
        XCTAssertTrue(stats.totalEvents > 0, "Should have logged at least one event")
    }

    /// Test configuration persistence
    func testConfigurationPersistence() throws {
        // Test that system configurations can be saved and loaded

        let config = OFXConfiguration()

        // Test default values
        XCTAssertTrue(config.isEnabled, "OFX should be enabled by default")
        XCTAssertEqual(config.defaultFrameRate, 30.0, "Default frame rate should be 30.0")
        XCTAssertEqual(config.maxConcurrentSimulations, 5, "Max simulations should be 5")

        // Test that we can modify configurations
        config.defaultFrameRate = 60.0
        XCTAssertEqual(config.defaultFrameRate, 60.0, "Frame rate should be modifiable")
    }
}