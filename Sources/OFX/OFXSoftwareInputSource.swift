import Foundation
import Common
import Logging

/// Software-based OFX input source for use when no physical DeckLink hardware is available.
/// Wraps OFX plugin functionality into a CaptureSource-compatible object.
public class OFXSoftwareInputSource: CaptureSourceBase, CaptureSource {
    /// Whether this source represents a physical device
    public let isPhysicalDevice: Bool

    /// OFX plugin identifier (optional, used for Resolve OFX input mode)
    public let ofxPluginId: String?

    /// Whether simulation mode is enabled (test pattern generation)
    public let enableSimulation: Bool

    /// Create an OFX software input source
    /// - Parameters:
    ///   - id: Unique identifier for this source
    ///   - name: Display name for UI
    ///   - isPhysicalDevice: Whether this represents a physical device
    ///   - ofxPluginId: Optional OFX plugin ID for Resolve integration
    ///   - enableSimulation: Whether to enable test pattern simulation
    public init(
        id: String,
        name: String,
        isPhysicalDevice: Bool = false,
        ofxPluginId: String? = nil,
        enableSimulation: Bool = false
    ) {
        self.isPhysicalDevice = isPhysicalDevice
        self.ofxPluginId = ofxPluginId
        self.enableSimulation = enableSimulation
        super.init(sourceId: id, sourceName: name)

        HDRLogger.debug(category: "OFX.SoftwareInput", "Created OFXSoftwareInputSource: \(name) (id=\(id))")
    }

    public override func connect() -> Bool {
        if let pluginId = ofxPluginId {
            HDRLogger.info(category: "OFX.SoftwareInput", "Connecting via OFX plugin: \(pluginId)")
        } else if enableSimulation {
            HDRLogger.info(category: "OFX.SoftwareInput", "Connecting in simulation mode")
        }
        return super.connect()
    }

    public override func startCapture() -> Bool {
        HDRLogger.info(category: "OFX.SoftwareInput", "Starting capture on \(sourceName)")
        return super.startCapture()
    }

    public override func stopCapture() {
        HDRLogger.info(category: "OFX.SoftwareInput", "Stopping capture on \(sourceName)")
        super.stopCapture()
    }
}
