import Foundation
import Metal
import Logging
import Common

/// Bridge between OFX device simulations and the existing capture pipeline
public class OFXCaptureBridge {
    public static let shared = OFXCaptureBridge()

    private let logCategory = "OFX.CaptureBridge"
    private var simulationToPipelineMap: [String: String] = [:] // simulationID -> pipelineID

    private init() {
        HDRLogger.debug(category: logCategory, "OFX Capture Bridge initialized")
    }

    /// Connect an OFX simulation to the capture pipeline
    /// - Parameters:
    ///   - simulationID: Identifier of the OFX simulation
    ///   - pipelineID: Identifier of the target pipeline
    /// - Returns: Boolean indicating success or failure
    public func connectSimulationToPipeline(simulationID: String, pipelineID: String) -> Bool {
        // In a real implementation, this would establish the actual connection
        // between OFX simulation and Metal capture pipeline

        simulationToPipelineMap[simulationID] = pipelineID

        HDRLogger.info(category: logCategory, "Connected simulation \(simulationID) to pipeline \(pipelineID)")
        return true
    }

    /// Disconnect an OFX simulation from the capture pipeline
    /// - Parameter simulationID: Identifier of the OFX simulation
    public func disconnectSimulationFromPipeline(simulationID: String) {
        simulationToPipelineMap.removeValue(forKey: simulationID)
        HDRLogger.info(category: logCategory, "Disconnected simulation \(simulationID) from pipeline")
    }

    /// Send frame data from OFX simulation to pipeline
    /// - Parameters:
    ///   - simulationID: Identifier of the OFX simulation
    ///   - frameData: OFX frame data to send
    ///   - pixelFormat: Pixel format of the frame (DeckLinkPixelFormat raw value)
    /// - Returns: Boolean indicating success or failure
    public func sendFrameToPipeline(simulationID: String, frameData: OFXFrameData, pixelFormat: DeckLinkPixelFormat) -> Bool {
        guard let pipelineID = simulationToPipelineMap[simulationID] else {
            HDRLogger.error(category: logCategory, "No pipeline connected for simulation \(simulationID)")
            return false
        }

        // In a real implementation, this would pass the frame to the actual pipeline
        HDRLogger.debug(category: logCategory, "Sent frame from simulation \(simulationID) to pipeline \(pipelineID)")

        return true
    }

    /// Get connection status for a simulation
    /// - Parameter simulationID: Identifier of the OFX simulation
    /// - Returns: Boolean indicating if connected
    public func isSimulationConnected(simulationID: String) -> Bool {
        return simulationToPipelineMap[simulationID] != nil
    }

    /// Update frame rate for a simulation
    /// - Parameters:
    ///   - simulationID: Identifier of the OFX simulation
    ///   - newFrameRate: New frame rate to set
    public func updateFrameRate(simulationID: String, newFrameRate: Double) {
        HDRLogger.info(category: logCategory, "Updated simulation \(simulationID) frame rate to \(newFrameRate)")
    }
}