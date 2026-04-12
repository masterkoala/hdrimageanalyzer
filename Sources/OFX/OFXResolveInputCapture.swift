import Foundation
import CoreVideo
import Metal
import Logging
import Common

/// OFX-based software input capture that simulates DeckLink by capturing from DaVinci Resolve's OFX pipeline.
/// This enables HDRImageAnalyzerPro to receive signal when no physical DeckLink device is present.
public final class OFXResolveInputCapture: CaptureSource {
    public static let shared = OFXResolveInputCapture()

    private let logCategory = "OFX.ResolveInput"
    private var isActive = false
    private var connectionURL: String?

    // CaptureSource protocol conformance
    public var isCapturing: Bool { isActive }
    public var currentSignalState: CaptureSignalState { signalState }
    public var sourceId: String { "ofx_resolve_input" }
    public var sourceName: String { "OFX Resolve Input" }

    // Capture session state
    private var width = 1920
    private var height = 1080
    private var frameRate: Double = 29.97

    // Handlers from capture pipeline (bridge to DeckLinkCaptureSession callbacks)
    private var onFramePixelBufferHandler: OFXFramePixelBufferHandler?
    private var onFormatChangeHandler: OFXFormatChangeHandler?
    private var onSignalStateChangeHandler: OFXSignalStateHandler?
    private var onTimecodeHandler: OFXTimecodeHandler?

    public var signalState: CaptureSignalState = .unknown

    // Simulation test patterns (when no real OFX input available)
    private var currentTestPattern: TestPattern?
    private let frameQueue = DispatchQueue(label: "HDRImageAnalyzerPro.OFX.resolveFrame", qos: .userInteractive)
    private var lastFrameTime: CFAbsoluteTime = 0
    private var frameInterval: TimeInterval = 1.0 / 30.0

    /// Connect to Resolve's OFX sharing mechanism
    public func connect() -> Bool {
        guard !isActive else { return true }

        connectionURL = nil // No URL needed - we use simulation mode by default
        isActive = true
        signalState = .unknown

        HDRLogger.info(category: logCategory, message: "Connected to DaVinci Resolve OFX (simulation mode)")
        return true
    }

    /// Disconnect from Resolve's OFX sharing mechanism
    public func disconnect() {
        guard isActive else { return }

        isActive = false
        connectionURL = nil
        stopSimulation()
        signalState = .unknown

        HDRLogger.info(category: logCategory, message: "Disconnected from DaVinci Resolve OFX")
    }

    /// Configure the capture session with handlers (Bridge to DeckLinkCaptureSession pattern)
    public func configureWithBasicParams(width: Int, height: Int, frameRate: Double) -> Bool {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.frameInterval = 1.0 / max(frameRate, 23.976)
        return true
    }

    public func startCapture() -> Bool {
        guard !isActive else { return false }

        isActive = true
        signalState = .present

        HDRLogger.info(category: logCategory, message: "Starting OFX Resolve Input capture \(width)x\(height) @ \(frameRate)fps")
        onSignalStateChangeHandler?(.present)

        // Start generating test frames if no real source
        startSimulation()

        return true
    }

    public func stopCapture() {
        guard isActive else { return }

        isActive = false
        signalState = .unknown

        HDRLogger.info(category: logCategory, message: "Stopping OFX Resolve Input capture")
        onSignalStateChangeHandler?(.lost)
        stopSimulation()
    }

    // MARK: - Simulation Frame Generation

    private func startSimulation() {
        frameQueue.async { [weak self] in
            guard let self = self else { return }
            self.generateTestPatternFrames()
        }
    }

    private func generateTestPatternFrames() {
        guard isActive else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastFrameTime >= frameInterval {
            lastFrameTime = now

            // Generate CVPixelBuffer with test pattern
            if let pixelBuffer = generateTestPattern(width: width, height: height) {
                self.onFramePixelBufferHandler?(pixelBuffer, width, height)

                // Simulate timecode update
                let timecodeString = formatTimecode(frameCount: UInt32(now * 1000))
                if lastFrameTime > frameInterval {
                    self.onTimecodeHandler?(timecodeString)
                }
            }
        }

        // Continue loop
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(frameRate == 60 ? 0.016 : 0.033)) { [weak self] in
            self?.generateTestPatternFrames()
        }
    }

    private func generateTestPattern(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let attrs = [
            kCVPixelBufferMetalCompatibilityKey: true as CFBoolean,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])

        if let baseAddr = CVPixelBufferGetBaseAddress(pb),
           let rgbaData = mutableDataForTestPattern(width: width, height: height) {
            rgbaData.withUnsafeBytes { rawBuffer in
                if let dataPtr = rawBuffer.baseAddress {
                    memcpy(baseAddr, dataPtr, rawBuffer.count)
                }
            }
        }

        CVPixelBufferUnlockBaseAddress(pb, [])

        return pb
    }

    private func formatTimecode(frameCount: UInt32) -> String {
        let hours = (frameCount / 3600) % 24
        let minutes = (frameCount / 60) % 60
        let seconds = frameCount % 60
        let frames = frameCount % 30
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    private func stopSimulation() {
        currentTestPattern = nil
    }

    // MARK: - Helper Methods

    private func mutableDataForTestPattern(width: Int, height: Int) -> Data? {
        let pixelCount = width * height
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)

        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4

                // Create color bars pattern
                let barWidth = max(1, width / 8)
                let barIndex = x / barWidth

                var color: (UInt8, UInt8, UInt8, UInt8)
                switch barIndex {
                case 0: color = (255, 0, 0, 255)    // Red
                case 1: color = (0, 255, 0, 255)    // Green
                case 2: color = (0, 0, 255, 255)    // Blue
                case 3: color = (255, 255, 0, 255)  // Cyan
                case 4: color = (255, 0, 255, 255)  // Magenta
                case 5: color = (0, 255, 255, 255)  // Yellow
                case 6: color = (255, 255, 255, 255) // White
                default: color = (0, 0, 0, 255)     // Black
                }

                pixels[idx] = color.0    // Blue
                pixels[idx + 1] = color.1 // Green
                pixels[idx + 2] = color.2 // Red
                pixels[idx + 3] = color.3 // Alpha

                // Add gradient overlay for HDR visualization
                if x < width / 4 {
                    let gradVal = UInt8((x * 255) / (width / 4))
                    pixels[idx] = min(pixels[idx], gradVal)
                }
            }
        }

        return Data(bytes: &pixels, count: pixels.count)
    }
}

/// Test pattern types for simulation mode
public enum TestPattern {
    case colorBars
    case grayscale
    case checkerboard
    case solidColor(UInt8, UInt8, UInt8)
}
