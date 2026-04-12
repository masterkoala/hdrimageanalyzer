import XCTest
@testable import HDRImageAnalyzerPro

/// Integration tests for OFX connection capabilities
final class OFXIntegrationTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        try super.tearDownWithError()
    }

    /// Test OFX plugin manager functionality
    func testOFXPluginManagerInitialization() throws {
        let pluginManager = OFXPluginManager.shared

        XCTAssertNotNil(pluginManager, "OFX Plugin Manager should not be nil")
        XCTAssertTrue(pluginManager.enumeratePlugins().isEmpty, "Initially, no plugins should be loaded")
    }

    /// Test OFX device simulation creation
    func testOFXDeviceSimulationCreation() throws {
        let simulation = OFXDeviceSimulation.shared

        // Create a test pattern simulation
        let testPatternID = simulation.createTestPatternSimulation(
            name: "Test Pattern 1",
            resolution: "1920x1080",
            frameRate: 30.0
        )

        XCTAssertNotNil(testPatternID, "Test pattern simulation should be created")
        XCTAssertTrue(simulation.listActiveSimulations().contains(testPatternID!), "Created simulation should be in active list")
    }

    /// Test OFX capture bridge functionality
    func testOFXCaptureBridgeConnection() throws {
        let bridge = OFXCaptureBridge.shared

        // Create a simulation
        let simulation = OFXDeviceSimulation.shared
        let simulationID = simulation.createTestPatternSimulation(
            name: "Bridge Test",
            resolution: "1920x1080",
            frameRate: 30.0
        )

        XCTAssertNotNil(simulationID, "Simulation should be created")

        // Connect to pipeline (this would normally connect to a real pipeline)
        let isConnected = bridge.connectSimulationToPipeline(
            simulationID: simulationID!,
            pipelineID: "TestPipeline"
        )

        XCTAssertTrue(isConnected, "Simulation should be connectable to pipeline")
    }

    /// Test OFX configuration loading
    func testOFXConfiguration() throws {
        let config = OFXConfiguration()

        XCTAssertTrue(config.isEnabled, "OFX should be enabled by default")
        XCTAssertEqual(config.defaultFrameRate, 30.0, "Default frame rate should be 30.0")
        XCTAssertEqual(config.defaultResolution, "1920x1080", "Default resolution should be 1920x1080")
        XCTAssertTrue(config.useHardwareAcceleration, "Hardware acceleration should be enabled by default")
    }

    /// Test end-to-end OFX workflow
    func testOFXWorkflow() throws {
        let pluginManager = OFXPluginManager.shared
        let simulation = OFXDeviceSimulation.shared
        let bridge = OFXCaptureBridge.shared

        // Create a simulation
        let simulationID = simulation.createTestPatternSimulation(
            name: "End-to-End Test",
            resolution: "1920x1080",
            frameRate: 60.0
        )

        XCTAssertNotNil(simulationID, "Simulation should be created")

        // Start the simulation
        let started = simulation.startSimulation(simulationID: simulationID!)
        XCTAssertTrue(started, "Simulation should start successfully")

        // Connect to pipeline
        let connected = bridge.connectSimulationToPipeline(
            simulationID: simulationID!,
            pipelineID: "MainPipeline"
        )

        XCTAssertTrue(connected, "Should be able to connect simulation to pipeline")

        // Verify connection status
        let isConnectionActive = bridge.isSimulationConnected(simulationID: simulationID!)
        XCTAssertTrue(isConnectionActive, "Connection should be active")

        // Stop the simulation
        simulation.stopSimulation(simulationID: simulationID!)

        // Verify simulation is stopped
        XCTAssertFalse(simulation.getSimulationInfo(simulationID: simulationID!)?.isRunning ?? true, "Simulation should be stopped")
    }
}