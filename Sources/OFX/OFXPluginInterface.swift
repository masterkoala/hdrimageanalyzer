import Foundation
import Logging

/// Interface for OFX plugins that can be used with HDRImageAnalyzerPro
public protocol OFXPlugin {
    /// Plugin identifier
    var pluginID: String { get }

    /// Plugin name
    var name: String { get }

    /// Plugin version
    var version: String { get }

    /// Initialize the plugin
    /// - Returns: Boolean indicating success or failure
    func initialize() -> Bool

    /// Deinitialize the plugin
    func deinitialize()

    /// Get plugin capabilities
    /// - Returns: Array of supported capabilities
    func getCapabilities() -> [String]

    /// Process a frame from the plugin
    /// - Parameter frameData: Raw frame data from the plugin
    /// - Returns: Processed frame or nil if failed
    func processFrame(frameData: Data) -> Data?

    /// Start plugin operation
    /// - Returns: Boolean indicating success or failure
    func start() -> Bool

    /// Stop plugin operation
    func stop()
}

/// Basic implementation of an OFX plugin for HDRImageAnalyzerPro
public class OFXPluginBase: OFXPlugin {
    public let pluginID: String
    public let name: String
    public let version: String

    private var isInitialized: Bool = false
    private let logCategory = "OFX.PluginBase"

    public init(pluginID: String, name: String, version: String) {
        self.pluginID = pluginID
        self.name = name
        self.version = version

        HDRLogger.debug(category: logCategory, message: "Created OFX plugin \(name) v\(version)")
    }

    public func initialize() -> Bool {
        isInitialized = true
        HDRLogger.info(category: logCategory, message: "Initialized plugin \(name)")
        return true
    }

    public func deinitialize() {
        isInitialized = false
        HDRLogger.info(category: logCategory, message: "Deinitialized plugin \(name)")
    }

    public func getCapabilities() -> [String] {
        return ["video-input", "test-pattern-generation"]
    }

    public func processFrame(frameData: Data) -> Data? {
        // In a real implementation, this would process the frame data
        HDRLogger.debug(category: logCategory, message: "Processing frame with plugin \(name)")
        return frameData
    }

    public func start() -> Bool {
        HDRLogger.info(category: logCategory, message: "Started plugin \(name)")
        return true
    }

    public func stop() {
        HDRLogger.info(category: logCategory, message: "Stopped plugin \(name)")
    }
}