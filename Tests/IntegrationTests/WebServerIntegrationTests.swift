import XCTest
@testable import HDRImageAnalyzerPro

/// Integration tests for Enhanced Web Server
final class WebServerIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        try super.tearDownWithError()
    }

    /// Test web server initialization
    func testWebServerInitialization() throws {
        let webServer = EnhancedWebServer.shared

        XCTAssertNotNil(webServer, "Enhanced Web Server should not be nil")
        XCTAssertEqual(webServer.port, 8080, "Default port should be 8080")
        XCTAssertTrue(webServer.enableOFXIntegration, "OFX integration should be enabled by default")
    }

    /// Test server start and stop functionality
    func testWebServerStartStop() throws {
        let webServer = EnhancedWebServer.shared

        // Note: In a real test environment, we would actually start/stop the server
        // For now, we'll just verify that the methods exist and don't crash

        // Test that we can access server statistics before starting
        let statsBefore = webServer.getStatistics()
        XCTAssertNotNil(statsBefore, "Statistics should be available before server start")

        // Test reset functionality
        webServer.resetStatistics()
        let statsAfterReset = webServer.getStatistics()
        XCTAssertEqual(statsAfterReset.requestCount, 0, "Request count should be reset to 0")
    }

    /// Test OFX device connection management
    func testOFXDeviceConnections() throws {
        let webServer = EnhancedWebServer.shared

        // Create a test device connection
        let testDevice = OFXDeviceConnection(deviceID: "TestDevice123", deviceType: "TestSimulator")

        // Add the device
        webServer.addOFXDeviceConnection(deviceID: "TestDevice123", connection: testDevice)

        // Verify device was added
        let devices = webServer.getConnectedOFXDevices()
        XCTAssertTrue(devices.contains("TestDevice123"), "Added device should be in connected list")

        // Remove the device
        webServer.removeOFXDeviceConnection(deviceID: "TestDevice123")

        // Verify device was removed
        let devicesAfterRemoval = webServer.getConnectedOFXDevices()
        XCTAssertFalse(devicesAfterRemoval.contains("TestDevice123"), "Removed device should not be in connected list")
    }

    /// Test server statistics
    func testServerStatistics() throws {
        let webServer = EnhancedWebServer.shared

        // Get initial stats
        let initialStats = webServer.getStatistics()

        XCTAssertGreaterThan(initialStats.port, 0, "Port should be positive")
        XCTAssertGreaterThanOrEqual(initialStats.uptime, 0.0, "Uptime should be non-negative")

        // Reset statistics
        webServer.resetStatistics()

        let resetStats = webServer.getStatistics()
        XCTAssertEqual(resetStats.requestCount, 0, "Request count should be reset to 0")
    }

    /// Test configuration functionality
    func testServerConfiguration() throws {
        let webServer = EnhancedWebServer.shared

        // Test that we can modify settings
        webServer.port = 8081
        XCTAssertEqual(webServer.port, 8081, "Port should be modifiable")

        webServer.enableOFXIntegration = false
        XCTAssertFalse(webServer.enableOFXIntegration, "OFX integration should be disableable")
    }

    /// Test device connection lifecycle
    func testDeviceConnectionLifecycle() throws {
        let webServer = EnhancedWebServer.shared

        // Add multiple devices
        let device1 = OFXDeviceConnection(deviceID: "Device1", deviceType: "Simulator1")
        let device2 = OFXDeviceConnection(deviceID: "Device2", deviceType: "Simulator2")

        webServer.addOFXDeviceConnection(deviceID: "Device1", connection: device1)
        webServer.addOFXDeviceConnection(deviceID: "Device2", connection: device2)

        // Verify both devices are connected
        let devices = webServer.getConnectedOFXDevices()
        XCTAssertEqual(devices.count, 2, "Should have 2 connected devices")
        XCTAssertTrue(devices.contains("Device1"), "Device1 should be connected")
        XCTAssertTrue(devices.contains("Device2"), "Device2 should be connected")

        // Remove one device
        webServer.removeOFXDeviceConnection(deviceID: "Device1")

        // Verify only one device remains
        let remainingDevices = webServer.getConnectedOFXDevices()
        XCTAssertEqual(remainingDevices.count, 1, "Should have 1 connected device after removal")
        XCTAssertFalse(remainingDevices.contains("Device1"), "Device1 should not be connected after removal")
        XCTAssertTrue(remainingDevices.contains("Device2"), "Device2 should still be connected")
    }
}