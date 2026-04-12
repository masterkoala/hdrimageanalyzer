import Foundation
import Metal
import Logging
import Common

/// Manages software-based video input simulation using OFX plugins
public class OFXDeviceSimulation {
    public static let shared = OFXDeviceSimulation()

    private let logCategory = "OFX.DeviceSimulation"
    private var activeSimulations: [String: OFXVideoSimulation] = [:]

    private init() {
        HDRLogger.debug(category: logCategory, "OFX Device Simulation initialized")
    }

    /// Create a test pattern simulation
    /// - Parameters:
    ///   - name: Name of the test pattern
    ///   - resolution: Video resolution as CGSize
    ///   - frameRate: Frame rate for the simulation
    /// - Returns: Identifier for the created simulation
    public func createTestPatternSimulation(name: String, resolution: CGSize = CGSize(width: 1920, height: 1080), frameRate: Double) -> String? {
        let simulationID = "TestPattern_\(UUID().uuidString)"

        let simulation = OFXVideoSimulation(
            id: simulationID,
            name: name,
            type: .testPattern,
            resolution: resolution,
            frameRate: frameRate
        )

        activeSimulations[simulationID] = simulation

        HDRLogger.info(category: logCategory, "Created test pattern simulation \(simulationID)")
        return simulationID
    }

    /// Create a calibration sequence simulation
    /// - Parameters:
    ///   - name: Name of the calibration sequence
    ///   - resolution: Video resolution as CGSize
    ///   - frameRate: Frame rate for the simulation
    /// - Returns: Identifier for the created simulation
    public func createCalibrationSimulation(name: String, resolution: CGSize = CGSize(width: 1920, height: 1080), frameRate: Double) -> String? {
        let simulationID = "Calibration_\(UUID().uuidString)"

        let simulation = OFXVideoSimulation(
            id: simulationID,
            name: name,
            type: .calibration,
            resolution: resolution,
            frameRate: frameRate
        )

        activeSimulations[simulationID] = simulation

        HDRLogger.info(category: logCategory, "Created calibration simulation \(simulationID)")
        return simulationID
    }

    /// Create a video file playback simulation
    /// - Parameters:
    ///   - fileName: Name of the video file to play
    ///   - resolution: Video resolution as CGSize
    ///   - frameRate: Frame rate for the playback
    /// - Returns: Identifier for the created simulation
    public func createVideoPlaybackSimulation(fileName: String, resolution: CGSize = CGSize(width: 1920, height: 1080), frameRate: Double) -> String? {
        let simulationID = "VideoPlayback_\(UUID().uuidString)"

        let simulation = OFXVideoSimulation(
            id: simulationID,
            name: fileName,
            type: .videoPlayback,
            resolution: resolution,
            frameRate: frameRate
        )

        activeSimulations[simulationID] = simulation

        HDRLogger.info(category: logCategory, "Created video playback simulation \(simulationID)")
        return simulationID
    }

    /// Start a simulation
    /// - Parameter simulationID: Identifier of the simulation to start
    /// - Returns: Boolean indicating success or failure
    public func startSimulation(simulationID: String) -> Bool {
        guard let simulation = activeSimulations[simulationID] else {
            HDRLogger.error(category: logCategory, "Cannot start non-existent simulation \(simulationID)")
            return false
        }

        simulation.start()
        HDRLogger.info(category: logCategory, "Started simulation \(simulationID)")
        return true
    }

    /// Stop a simulation
    /// - Parameter simulationID: Identifier of the simulation to stop
    public func stopSimulation(simulationID: String) {
        guard let simulation = activeSimulations[simulationID] else {
            HDRLogger.error(category: logCategory, "Cannot stop non-existent simulation \(simulationID)")
            return
        }

        simulation.stop()
        HDRLogger.info(category: logCategory, "Stopped simulation \(simulationID)")
    }

    /// Get information about a simulation
    /// - Parameter simulationID: Identifier of the simulation
    /// - Returns: Simulation information or nil if not found
    public func getSimulationInfo(simulationID: String) -> OFXVideoSimulation? {
        return activeSimulations[simulationID]
    }

    /// List all active simulations
    /// - Returns: Array of active simulation identifiers
    public func listActiveSimulations() -> [String] {
        return Array(activeSimulations.keys)
    }
}

// OFXVideoSimulation and OFXSimulationType are defined in OFXInputSource.swift