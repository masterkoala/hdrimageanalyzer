import Foundation
import CoreVideo
import Metal
import Logging
import Common

/// OFX format change event — local equivalent of DeckLinkFormatChangeEvent for the OFX module
/// (the Capture module's DeckLinkFormatChangeEvent is not accessible from OFX).
public struct OFXFormatChangeEvent {
    public let notificationEvents: UInt32
    public let displayModeId: UInt32
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let detectedSignalFlags: UInt32

    public init(notificationEvents: UInt32, displayModeId: UInt32, width: Int, height: Int, frameRate: Double, detectedSignalFlags: UInt32) {
        self.notificationEvents = notificationEvents
        self.displayModeId = displayModeId
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.detectedSignalFlags = detectedSignalFlags
    }
}

/// OFX Input Source that captures video from DaVinci Resolve's OFX pipeline.
/// This acts as a virtual input when no DeckLink hardware is available.
public final class OFXInputSource: CaptureSourceBase {
    /// Shared singleton instance
    public static let shared = OFXInputSource()

    private var resolveConnectionURL: String?
    private var activeSimulations: [String: OFXVideoSimulation] = [:]

    // Frame delivery state
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameInterval: TimeInterval = 1.0 / 30.0
    private let frameQueue = DispatchQueue(label: "HDRImageAnalyzerPro.OFX.inputFrame", qos: .userInteractive)

    // Frame delivery callbacks (Bridge pattern - similar to DeckLinkCaptureSession)
    private var onPixelBufferHandler: ((CVPixelBuffer, Int, Int, DeckLinkPixelFormat) -> Void)?
    private var onFormatChangeHandler: ((OFXFormatChangeEvent) -> Void)?
    private var onSignalStateHandler: ((CaptureSignalState) -> Void)?

    // Configuration state
    private var captureWidth = 1920
    private var captureHeight = 1080
    private var captureFrameRate: Double = 30.0
    private var capturePixelFormat: DeckLinkPixelFormat = .rgb8

    /// Create an OFX input source instance
    private init() {
        super.init(sourceId: "ofx_input_source", sourceName: "OFX Resolve Input")

        HDRLogger.info(category: "OFX.InputSource", "Created OFX Input Source \(sourceName)")
    }

    // MARK: - Connection Management

    /// Connect to DaVinci Resolve's OFX sharing mechanism
    /// - Parameter applicationURL: Optional URL to Resolve application (nil for auto-connect)
    /// - Returns: Boolean indicating connection success
    public func connect(resolveApplicationURL: String? = nil) -> Bool {
        guard !isCapturing else { return true }

        resolveConnectionURL = resolveApplicationURL

        if let url = resolveApplicationURL {
            HDRLogger.info(category: "OFX.InputSource", "Connecting to Resolve OFX at \(url)")
        } else {
            HDRLogger.info(category: "OFX.InputSource", "Auto-connecting to DaVinci Resolve")
        }

        signalState = .unknown
        return true
    }

    /// Disconnect from Resolve and stop all simulations
    public override func disconnect() {
        resolveConnectionURL = nil

        for simulationId in activeSimulations.keys {
            activeSimulations[simulationId]?.stop()
        }
        activeSimulations.removeAll()

        signalState = .unknown
        super.disconnect()

        HDRLogger.info(category: "OFX.InputSource", "Disconnected from Resolve OFX")
    }

    // MARK: - Simulation Management

    /// Create a test pattern simulation (color bars, gradients, etc.)
    public func createTestPatternSimulation(
        name: String,
        resolution: CGSize = CGSize(width: 1920, height: 1080),
        frameRate: Double = 30.0
    ) -> String? {
        let simulationId = UUID().uuidString

        let simulation = OFXVideoSimulation(
            id: simulationId,
            name: name,
            type: .testPattern,
            resolution: resolution,
            frameRate: frameRate
        )

        activeSimulations[simulationId] = simulation

        HDRLogger.info(category: "OFX.InputSource", "Created test pattern simulation \(simulationId) - \(name)")

        return simulationId
    }

    /// Create a calibration sequence simulation (HDR test patterns, tone curves)
    public func createCalibrationSimulation(
        name: String,
        resolution: CGSize = CGSize(width: 1920, height: 1080),
        frameRate: Double = 30.0
    ) -> String? {
        let simulationId = UUID().uuidString

        let simulation = OFXVideoSimulation(
            id: simulationId,
            name: name,
            type: .calibration,
            resolution: resolution,
            frameRate: frameRate
        )

        activeSimulations[simulationId] = simulation

        HDRLogger.info(category: "OFX.InputSource", "Created calibration simulation \(simulationId) - \(name)")

        return simulationId
    }

    /// Create a video playback simulation (from file or URL)
    public func createVideoPlaybackSimulation(
        name: String,
        resolution: CGSize = CGSize(width: 1920, height: 1080),
        frameRate: Double = 30.0
    ) -> String? {
        let simulationId = UUID().uuidString

        let simulation = OFXVideoSimulation(
            id: simulationId,
            name: name,
            type: .videoPlayback,
            resolution: resolution,
            frameRate: frameRate
        )

        activeSimulations[simulationId] = simulation

        HDRLogger.info(category: "OFX.InputSource", "Created video playback simulation \(simulationId) - \(name)")

        return simulationId
    }

    /// Get simulation info by ID
    public func getSimulationInfo(_ simulationId: String) -> OFXVideoSimulation? {
        return activeSimulations[simulationId]
    }

    /// List all active simulations
    public func listActiveSimulations() -> [String] {
        return Array(activeSimulations.keys)
    }

    // MARK: - Capture Configuration

    /// Configure capture parameters
    public func configureCapture(
        width: Int,
        height: Int,
        frameRate: Double,
        pixelFormat: DeckLinkPixelFormat
    ) -> Bool {
        captureWidth = width
        captureHeight = height
        captureFrameRate = frameRate
        capturePixelFormat = pixelFormat

        frameInterval = 1.0 / max(frameRate, 23.976)

        HDRLogger.debug(category: "OFX.InputSource", "Configured capture \(width)x\(height) @ \(frameRate)fps \(pixelFormat)")

        return true
    }

    /// Configure the pixel buffer callback (Bridge to DeckLinkCaptureSession)
    public func configureFrameHandler(handler: @escaping (CVPixelBuffer, Int, Int, DeckLinkPixelFormat) -> Void) {
        onPixelBufferHandler = handler
    }

    /// Configure format change callback
    public func configureFormatChangeHandler(handler: @escaping (OFXFormatChangeEvent) -> Void) {
        onFormatChangeHandler = handler
    }

    /// Configure signal state change callback
    public func configureSignalStateHandler(handler: @escaping (CaptureSignalState) -> Void) {
        onSignalStateHandler = handler
    }

    // MARK: - Capture Control

    public override func startCapture() -> Bool {
        guard !isCapturing else { return false }

        isActive = true
        signalState = .present
        lastFrameTime = CFAbsoluteTimeGetCurrent()

        HDRLogger.info(category: "OFX.InputSource", "Started OFX capture \(captureWidth)x\(captureHeight) @ \(captureFrameRate)fps")

        // Notify format change if configured
        if let handler = onFormatChangeHandler {
            let event = OFXFormatChangeEvent(
                notificationEvents: 0,
                displayModeId: 1,
                width: captureWidth,
                height: captureHeight,
                frameRate: captureFrameRate,
                detectedSignalFlags: 0
            )
            handler(event)
        }

        // Notify signal state change if configured
        if let handler = onSignalStateHandler {
            DispatchQueue.main.async { [weak self] in
                guard let _ = self else { return }
                handler(.present)
            }
        }

        // Start generating frames from active simulations
        startFrameGeneration()

        return true
    }

    public override func stopCapture() {
        guard isCapturing else { return }

        isActive = false
        signalState = .lost

        HDRLogger.info(category: "OFX.InputSource", "Stopped OFX capture")

        // Notify signal state change if configured
        if let handler = onSignalStateHandler {
            DispatchQueue.main.async { [weak self] in
                guard let _ = self else { return }
                handler(.lost)
            }
        }
    }

    // MARK: - Frame Generation

    private func startFrameGeneration() {
        frameQueue.async { [weak self] in
            guard let self = self else { return }
            self.generateFrames()
        }
    }

    private func generateFrames() {
        guard isCapturing else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFrameTime >= frameInterval {
            lastFrameTime = now

            // Get current simulation or use default test pattern
            if let activeId = activeSimulations.keys.first,
               let simulation = activeSimulations[activeId], simulation.isRunning,
               let frameData = simulation.generateNextFrame() {

                deliverFrame(frameData)
            } else {
                // Generate default color bars
                deliverDefaultTestPattern()
            }
        }

        // Continue the loop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.generateFrames()
        }
    }

    private func deliverDefaultTestPattern() {
        guard let pixelBuffer = generateColorBars(width: captureWidth, height: captureHeight),
              let handler = onPixelBufferHandler else { return }

        handler(pixelBuffer, captureWidth, captureHeight, capturePixelFormat)
    }

    private func deliverFrame(_ frameData: OFXFrameData) {
        guard let handler = onPixelBufferHandler else { return }

        // Convert OFXFrameData to CVPixelBuffer
        var pixelBuffer: CVPixelBuffer?

        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frameData.width,
            frameData.height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        if status == kCVReturnSuccess, let pb = pixelBuffer {
            CVPixelBufferLockBaseAddress(pb, [])
            if let baseAddr = CVPixelBufferGetBaseAddress(pb) {
                frameData.pixels.withUnsafeBytes { rawBuffer in
                    if let dataPtr = rawBuffer.baseAddress {
                        memcpy(baseAddr, dataPtr, rawBuffer.count)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])

            handler(pb, frameData.width, frameData.height, capturePixelFormat)
        }
    }

    private func generateColorBars(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])

        if let baseAddr = CVPixelBufferGetBaseAddress(pb) {
            for y in 0..<height {
                for x in 0..<width {
                    let idx = (y * width + x) * 4
                    let ptr = baseAddr.bindMemory(to: UInt8.self, capacity: width * height * 4)

                    // Color bars pattern (8 vertical bars)
                    let barWidth = max(1, width / 8)
                    let barIndex = x / barWidth

                    var color: UInt8
                    switch barIndex {
                    case 0: color = 255    // Red (B=255 in BGRA)
                    case 1: color = 0      // Green (B=0)
                    case 2: color = 0      // Blue
                    case 3: color = 0      // Cyan
                    case 4: color = 0      // Magenta
                    case 5: color = 0      // Yellow
                    case 6: color = 255    // White
                    default: color = 0     // Black
                    }

                    ptr[idx] = color        // Blue channel
                    ptr[idx + 1] = 0        // Green (simplified)
                    ptr[idx + 2] = 255 - color // Red inverted for variety
                    ptr[idx + 3] = 255      // Alpha
                }
            }
        }

        CVPixelBufferUnlockBaseAddress(pb, [])

        return pb
    }
}

/// Frame data wrapper for OFX frame transfer
public struct OFXFrameData {
    public let pixels: Data
    public let width: Int
    public let height: Int
    public let format: OSType
    public let timestamp: Double

    public init(pixels: Data, width: Int, height: Int, format: OSType = kCVPixelFormatType_32BGRA, timestamp: Double? = nil) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.format = format
        self.timestamp = timestamp ?? CFAbsoluteTimeGetCurrent()
    }

    public var byteCount: Int { return pixels.count }
}

/// Type of video simulation
public enum OFXSimulationType: String {
    case testPattern = "Test Pattern"
    case calibration = "Calibration Sequence"
    case videoPlayback = "Video Playback"
}

/// Represents a video simulation that generates frames
public class OFXVideoSimulation {
    public let id: String
    public let name: String
    public let type: OFXSimulationType
    public let resolution: CGSize
    public let frameRate: Double

    public private(set) var isRunning = false
    private var frameCount: UInt64 = 0
    private var timer: Timer?

    public init(id: String, name: String, type: OFXSimulationType, resolution: CGSize, frameRate: Double) {
        self.id = id
        self.name = name
        self.type = type
        self.resolution = resolution
        self.frameRate = frameRate
    }

    public func start() {
        isRunning = true
        HDRLogger.info(category: "OFX.Simulation", "Started simulation \(name)")
    }

    public func stop() {
        isRunning = false
        timer?.invalidate()
        HDRLogger.info(category: "OFX.Simulation", "Stopped simulation \(name)")
    }

    public func generateNextFrame() -> OFXFrameData? {
        guard isRunning else { return nil }

        frameCount += 1
        let imageData = generateTestImageData()

        return OFXFrameData(
            pixels: imageData,
            width: Int(resolution.width),
            height: Int(resolution.height)
        )
    }

    private func generateTestImageData() -> Data {
        let pixelCount = Int(resolution.width * resolution.height)
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)

        for y in 0..<Int(resolution.height) {
            for x in 0..<Int(resolution.width) {
                let idx = (y * Int(resolution.width) + x) * 4

                // Create color bars with gradients
                let barWidth = max(1, Int(resolution.width) / 8)
                let barIndex = x / barWidth

                var r: UInt8 = 0
                var g: UInt8 = 0
                var b: UInt8 = 0

                switch barIndex {
                case 0: (r, g, b) = (255, 0, 0)    // Red
                case 1: (r, g, b) = (0, 255, 0)    // Green
                case 2: (r, g, b) = (0, 0, 255)    // Blue
                case 3: (r, g, b) = (255, 255, 0)  // Cyan
                case 4: (r, g, b) = (255, 0, 255)  // Magenta
                case 5: (r, g, b) = (0, 255, 255)  // Yellow
                case 6: (r, g, b) = (255, 255, 255) // White
                default: (r, g, b) = (0, 0, 0)     // Black
                }

                pixels[idx] = b           // BGRA order
                pixels[idx + 1] = g
                pixels[idx + 2] = r
                pixels[idx + 3] = 255     // Alpha
            }
        }

        return Data(bytes: &pixels, count: pixels.count)
    }
}
