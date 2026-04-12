import SwiftUI
import Metal
import MetalKit
import CoreVideo
import Logging
import Common
import Capture
import MetalEngine
import Scopes
import Metadata

// MARK: - SC-021: Pixel Picker result

/// Result of sampling one pixel from the display texture (R, G, B, A in 0...255).
/// SC-022: Extended with hex, float, nits, IRE display values.
public struct PixelPickerResult {
    public let x: Int
    public let y: Int
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public let a: UInt8

    /// SC-022: Hex string #RRGGBB.
    public var hexString: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    /// SC-022: R, G, B as float 0.0...1.0.
    public var rFloat: Double { Double(r) / 255 }
    public var gFloat: Double { Double(g) / 255 }
    public var bFloat: Double { Double(b) / 255 }

    /// SC-022: BT.709 luma (0...255) from R,G,B.
    public var luma: Double {
        0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
    }

    /// SC-022: SDR nits (0...100), assuming 100 nits = 255.
    public var nits: Double { (luma / 255) * 100 }

    /// SC-022: IRE (0...100) from luma.
    public var ire: Double { (luma / 255) * 100 }
}

// MARK: - SC-022: Pixel picker HUD (hex, decimal, float, nits, IRE)

/// Shared HUD view for pixel picker result — used by CapturePreviewView and VideoPreviewOnlyView.
public struct PixelPickerHUDView: View {
    let result: PixelPickerResult

    public init(result: PixelPickerResult) { self.result = result }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("(\(result.x), \(result.y))")
                .font(.system(.caption2, design: .monospaced))
            Text("Dec R:\(result.r) G:\(result.g) B:\(result.b)  Hex \(result.hexString)")
                .font(.system(.caption2, design: .monospaced))
            Text(String(format: "Float R:%.3f G:%.3f B:%.3f", result.rFloat, result.gFloat, result.bFloat))
                .font(.system(.caption2, design: .monospaced))
            Text(String(format: "Nits: %.1f  IRE: %.1f", result.nits, result.ire))
                .font(.system(.caption2, design: .monospaced))
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .cornerRadius(4)
    }
}

// MARK: - PERF-003: Capture metadata state (split from CapturePreviewState)

/// Volatile metadata that changes at frame rate (timecode, format, DV/HDR10 metadata, signal state).
/// Separated from CapturePreviewState so that metadata updates don't trigger objectWillChange on the
/// parent — preventing cascading SwiftUI body re-evaluations of VideoPreviewOnlyView and scope views.
public final class CaptureMetadataState: ObservableObject {
    /// Status bar (UI-012): DL-008 timecode from capture; nil when not live or no timecode.
    @Published public var currentTimecode: String?
    /// Status bar: live format from DL-006 onFormatChange; nil when not set (use selected mode for display).
    @Published public var currentFormatWidth: Int?
    @Published public var currentFormatHeight: Int?
    @Published public var currentFrameRate: Double?

    /// No valid source (CapturePreview: bmdFrameHasNoInputSource). Shown when capture is live but signal has no input.
    @Published public var showNoValidSource: Bool = false

    /// DV-009: Metadata display panel — Dolby Vision L1/L2 and HDR10 static from VANC (DL-009).
    @Published public var currentDolbyVisionL1: DolbyVisionLevel1Metadata?
    @Published public var currentDolbyVisionL2: DolbyVisionLevel2Metadata?
    @Published public var currentHDR10Static: HDR10StaticMetadata?

    /// DV-010: Ring buffer of L1 samples for timeline graph (min/max/avg PQ over time).
    @Published public var l1History: [DolbyVisionLevel1Metadata] = []
    public let maxL1HistoryCount = 512

    /// Throttle timecode UI updates to avoid SwiftUI re-renders every frame.
    var lastTimecodeUIUpdateTime: CFAbsoluteTime = 0
    let timecodeUIUpdateInterval: CFAbsoluteTime = 0.25

    /// Reset all metadata to nil/empty (e.g. on capture stop).
    public func reset() {
        showNoValidSource = false
        currentTimecode = nil
        lastTimecodeUIUpdateTime = 0
        currentDolbyVisionL1 = nil
        currentDolbyVisionL2 = nil
        currentHDR10Static = nil
        l1History = []
    }
}

// MARK: - Capture preview state

/// State for device/mode selection and live capture. Submits frames to Metal pipeline and drives preview.
/// Input flow matches CapturePreview sample: Device → Input connection → Display mode → Start (with optional Apply detected video mode).
/// PERF-003: Volatile metadata moved to CaptureMetadataState to prevent cascading SwiftUI invalidation.
public final class CapturePreviewState: ObservableObject {
    @Published public var devices: [DeckLinkDeviceInfo] = []
    @Published public var selectedDeviceIndex: Int = 0
    /// Supported input connections for the selected device (SDI, HDMI, etc.). Refreshed when device changes.
    @Published public var supportedInputConnections: [DeckLinkVideoConnection] = []
    /// Currently selected input connection (raw BMDVideoConnection). Set on device before listing modes / starting capture.
    @Published public var selectedInputConnection: UInt64 = 0
    @Published public var modes: [DeckLinkDisplayMode] = []
    @Published public var selectedModeIndex: Int = 0
    /// Pixel format for capture (DL-015: 12-bit RGB 4:4:4 supported).
    @Published public var selectedPixelFormat: DeckLinkPixelFormat = .v210
    /// Apply detected video mode (CapturePreview: bmdVideoInputEnableFormatDetection). When true, mode list is disabled during capture.
    @Published public var applyDetectedVideoMode: Bool = false
    /// True if the selected device supports input format detection (enables Apply detected video mode checkbox).
    @Published public var supportsInputFormatDetection: Bool = false
    @Published public var isLive: Bool = false
    @Published public var errorMessage: String?

    /// PERF-003: Volatile metadata in separate ObservableObject — changes here don't trigger
    /// objectWillChange on CapturePreviewState, so Video/scope quadrants aren't invalidated.
    public let metadata = CaptureMetadataState()

    /// UI-009: LUT file browser state (load .cube, drag-and-drop). When loaded, texture is applied to pipeline.
    @Published public var lutLoadState = LUTLoadState()

    /// SC-021: Pixel Picker — last sampled pixel (x, y, R, G, B, A). Nil when no pick or not live.
    @Published public var pixelPickerResult: PixelPickerResult?

    /// SC-024: Safe Area / Framing guide overlays. Action Safe = 90% frame; Title Safe = 80% frame.
    @Published public var showActionSafe: Bool = false
    @Published public var showTitleSafe: Bool = false

    /// Signal range for YCbCr→RGB conversion (Full or Legal). Synced to pipeline.signalRange.
    @Published public var selectedSignalRange: SignalRange = .full

    /// QC-009: Timed screenshot capture (every N seconds/frames). Use startTimedScreenshotCapture/stopTimedScreenshotCapture.
    public let timedScreenshotCapture = TimedScreenshotCapture()

    /// Thread-safe cache for Web UI GET /api/input. Updated on main; read by server thread without main.sync (avoids deadlock when main is in processFrame).
    private let inputSourceCacheLock = NSLock()
    private var inputSourceCachedPayload: Data?

    private let deviceManager = DeckLinkDeviceManager()
    private let ancillaryQueue = DispatchQueue(label: "com.hdr.metadata.ancillary")
    private var ancillaryPackets: [AncillaryPacket] = []
    private let maxAncillaryPackets = 128
    private var captureSession: DeckLinkCaptureSession?
    /// DV-011: Frame index for metadata alerting (gap/error). Incremented per updateMetadataFromPackets.
    private var metadataFrameIndex: UInt64 = 0
    /// DV-011: Shared alerting instance; wired to MetadataPipeline when capture is active.
    private let metadataAlerting = MetadataAlerting()
    /// Pipeline is created on first access (lazy) so Metal is available after window/context is ready; sample uses SDK screen preview, we use Metal for display.
    private var pipeline: MasterPipeline? {
        if _pipeline == nil {
            // #region agent log
            debugSessionLog(location: "CapturePreviewView.pipeline getter", message: "creating MasterPipeline(engine: nil)", data: ["wasNil": true], hypothesisId: "H1")
            // #endregion
            _pipeline = MasterPipeline(engine: nil)
            // #region agent log
            debugSessionLog(location: "CapturePreviewView.pipeline getter", message: "after MasterPipeline(engine: nil)", data: ["created": _pipeline != nil], hypothesisId: "H2")
            // #endregion
        }
        // Sync signal range to pipeline
        _pipeline?.signalRange = selectedSignalRange.shaderValue
        return _pipeline
    }
    private var _pipeline: MasterPipeline?
    private let logCategory = "UI.CapturePreview"

    public init(scope: WaveformScope? = nil) {
        self.scope = scope
        // CapturePreview sample: enable discovery at launch so device list is filled (addDevice via callback + Iterator fallback).
        startDeviceNotifications()
        refreshDevices()
    }

    /// Start DeckLink hot-plug notifications so device list refreshes when devices are added/removed (DL-012).
    public func startDeviceNotifications() {
        deviceManager.startDeviceNotifications()
    }

    /// Scope to receive display texture each frame (ScopeTextureUpdatable).
    @Published public var scope: WaveformScope?
    /// Histogram scope (SC-009) receives display texture each frame.
    @Published public var histogramScope: HistogramScope?

    public var selectedDeviceInfo: DeckLinkDeviceInfo? {
        guard selectedDeviceIndex >= 0, selectedDeviceIndex < devices.count else { return nil }
        return devices[selectedDeviceIndex]
    }

    /// Selected display mode (for status bar format/fps when not live or before format change). UI-012.
    public var selectedMode: DeckLinkDisplayMode? {
        guard selectedModeIndex >= 0, selectedModeIndex < modes.count else { return nil }
        return modes[selectedModeIndex]
    }

    /// Refresh device list. When mergeFromIterator is true (e.g. user tapped Refresh), merge from Iterator by name so devices not reported via callback are listed without duplicates.
    public func refreshDevices(mergeFromIterator: Bool = false) {
        if mergeFromIterator {
            deviceManager.refreshDeviceListFromIterator()
        }
        devices = deviceManager.enumerateDevices()
        if selectedDeviceIndex >= devices.count { selectedDeviceIndex = max(0, devices.count - 1) }
        refreshInputConnections()
        refreshModes()
        refreshInputSourceCache()
    }

    /// Refresh supported input connections for selected device and sync selectedInputConnection to device current (CapturePreview: refreshInputConnectionList).
    public func refreshInputConnections() {
        guard let info = selectedDeviceInfo else {
            supportedInputConnections = []
            selectedInputConnection = 0
            supportsInputFormatDetection = false
            return
        }
        let supported = DeckLinkGetSupportedInputConnections(deviceIndex: info.index)
        supportedInputConnections = supported
        supportsInputFormatDetection = DeckLinkDeviceSupportsInputFormatDetection(deviceIndex: info.index)
        let current = DeckLinkGetCurrentInputConnection(deviceIndex: info.index)
        if current != 0 && supported.contains(where: { $0.rawValue == current }) {
            selectedInputConnection = current
        } else if let first = supported.first {
            selectedInputConnection = first.rawValue
            _ = DeckLinkSetCurrentInputConnection(deviceIndex: info.index, connection: first.rawValue)
        } else {
            selectedInputConnection = 0
        }
    }

    /// Call when user changes input connection in UI (CapturePreview: newConnectionSelected). Sets connection on device and refreshes mode list.
    public func setInputConnectionAndRefreshModes(_ connection: UInt64) {
        selectedInputConnection = connection
        guard let info = selectedDeviceInfo else { return }
        _ = DeckLinkSetCurrentInputConnection(deviceIndex: info.index, connection: connection)
        refreshModes()
    }

    public func refreshModes() {
        guard let info = selectedDeviceInfo else { modes = []; return }
        let device = DeckLinkDevice(info: info)
        modes = device.displayModes()
        if selectedModeIndex >= modes.count { selectedModeIndex = max(0, modes.count - 1) }
        refreshInputSourceCache()
    }

    /// Build input source JSON for Web UI. Call on main thread only.
    private func buildInputSourcePayload() -> Data? {
        let devicesArray: [[String: Any]] = devices.enumerated().map { idx, info in
            let device = DeckLinkDevice(info: info)
            let modeList = device.displayModes()
            let modesArray = modeList.map { m in
                ["name": m.name, "width": m.width, "height": m.height, "frameRate": m.frameRate] as [String: Any]
            }
            return ["name": info.displayName, "modes": modesArray] as [String: Any]
        }
        let payload: [String: Any] = [
            "devices": devicesArray,
            "selectedDeviceIndex": selectedDeviceIndex,
            "selectedModeIndex": selectedModeIndex
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// Update cached payload for GET /api/input. Call from main thread (e.g. after refreshDevices/refreshModes or selection change).
    public func refreshInputSourceCache() {
        let data = buildInputSourcePayload()
        inputSourceCacheLock.lock()
        inputSourceCachedPayload = data
        inputSourceCacheLock.unlock()
    }

    /// Thread-safe read of cached input source payload. Used by Web UI provider; no main.sync to avoid deadlock when main is in processFrame.
    public func getInputSourceCachedData() -> Data? {
        inputSourceCacheLock.lock()
        defer { inputSourceCacheLock.unlock() }
        return inputSourceCachedPayload
    }

    // MARK: - QC-009: Timed screenshot capture

    /// Whether timed screenshot capture is currently running.
    public var isTimedScreenshotRunning: Bool { timedScreenshotCapture.isRunning }

    /// Start timed screenshot capture. Uses current pipeline to export display to PNG (QC-008). For frame-based mode, call tickTimedScreenshotFrame() from the preview draw loop.
    public func startTimedScreenshotCapture(mode: TimedScreenshotMode, outputDirectory: URL, filenamePrefix: String = "screenshot") {
        guard let pipeline = pipeline else {
            errorMessage = "No pipeline for timed screenshot."
            return
        }
        timedScreenshotCapture.start(mode: mode, outputDirectory: outputDirectory, filenamePrefix: filenamePrefix) { [weak pipeline] url in
            pipeline?.exportDisplayScreenshotToPNG(to: url) ?? false
        }
    }

    /// Stop timed screenshot capture.
    public func stopTimedScreenshotCapture() {
        timedScreenshotCapture.stop()
    }

    /// Call once per frame from the preview draw loop when using frame-based timed capture. No-op when not running or in time-based mode.
    public func tickTimedScreenshotFrame() {
        _ = timedScreenshotCapture.tickFrame()
    }

    public func startCapture() {
        guard let info = selectedDeviceInfo, selectedModeIndex >= 0, selectedModeIndex < modes.count else {
            errorMessage = "Select a device and display mode."
            return
        }
        stopCapture()
        // #region agent log
        let pipelineNil = (pipeline == nil)
        debugSessionLog(location: "CapturePreviewView.startCapture", message: "before guard pipeline", data: ["pipelineNil": pipelineNil], hypothesisId: "H1,H2")
        // #endregion
        guard let pipeline = pipeline else {
            errorMessage = "Metal pipeline unavailable. Ensure the app has a valid Metal device (e.g. run on Mac with GPU)."
            return
        }
        let deviceIndex = info.index
        let modeIndex = selectedModeIndex
        // Bridge uses CVPixelBuffer only when format is 32BGRA; otherwise bytes path (v210 etc).
        let session = DeckLinkCaptureSession(
            deviceIndex: deviceIndex,
            modeIndex: modeIndex,
            pixelFormat: selectedPixelFormat,
            applyDetectedInputMode: applyDetectedVideoMode,
            onFrame: { [weak pipeline] bytes, rowBytes, width, height, pixelFormat in
                guard let pipeline = pipeline else {
                    NSLog("[CaptureCallback] onFrame: pipeline is nil (weak ref dead)")
                    return
                }
                pipeline.submitFrame(
                    bytes: bytes,
                    rowBytes: rowBytes,
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat
                )
            },
            onFramePixelBuffer: { [weak pipeline] pixelBuffer, width, height, pixelFormat in
                guard let pipeline = pipeline else {
                    NSLog("[CaptureCallback] onFramePixelBuffer: pipeline is nil (weak ref dead)")
                    return
                }
                let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let byteCount = rowBytes * height
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                    NSLog("[CaptureCallback] onFramePixelBuffer: CVPixelBufferGetBaseAddress returned nil")
                    return
                }
                let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
                let pf: UInt32 = (format == kCVPixelFormatType_32BGRA) ? 0x42475241 : pixelFormat
                let copy = Data(bytes: base, count: byteCount)
                copy.withUnsafeBytes { raw in
                    guard let ptr = raw.baseAddress else { return }
                    pipeline.submitFrame(bytes: ptr, rowBytes: rowBytes, width: width, height: height, pixelFormat: pf)
                }
            },
            onFormatChange: { [weak self] event in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.metadata.currentFormatWidth = event.width
                    self.metadata.currentFormatHeight = event.height
                    self.metadata.currentFrameRate = event.frameRate
                    // QuadPreview: when apply detected mode, restart capture with detected format so feed shows correct signal.
                    if self.applyDetectedVideoMode, self.isLive, let info = self.selectedDeviceInfo {
                        let displayModeChanged = (event.notificationEvents & 1) != 0   // bmdVideoInputDisplayModeChanged
                        let colorspaceChanged = (event.notificationEvents & 4) != 0     // bmdVideoInputColorspaceChanged
                        if displayModeChanged || colorspaceChanged {
                            // Adapt pixel format based on detected signal flags (fixes UltraStudio 4K SDI).
                            var pixelFormatDidChange = false
                            if colorspaceChanged, let detectedFormat = event.recommendedPixelFormat {
                                if detectedFormat != self.selectedPixelFormat {
                                    HDRLogger.info(category: self.logCategory, "Format change: adapting pixel format from \(self.selectedPixelFormat) to \(detectedFormat) (flags=\(event.detectedSignalFlags))")
                                    self.selectedPixelFormat = detectedFormat
                                    pixelFormatDidChange = true
                                }
                            }
                            let modeIdx = DeckLinkModeIndexForDisplayMode(deviceIndex: info.index, displayModeId: event.displayModeId)
                            let needsModeChange = modeIdx >= 0 && modeIdx != self.selectedModeIndex && modeIdx < self.modes.count
                            let needsRestart = needsModeChange || pixelFormatDidChange
                            if needsModeChange {
                                self.selectedModeIndex = modeIdx
                            }
                            if needsRestart {
                                self.stopCapture()
                                self.startCapture()
                                HDRLogger.info(category: self.logCategory, "Format change: restarted capture with mode \(self.selectedModeIndex) \(event.width)x\(event.height) @ \(event.frameRate) fps pixelFormat=\(self.selectedPixelFormat)")
                            }
                        }
                    }
                }
            },
            onSignalStateChange: { [weak self] sigState in
                DispatchQueue.main.async {
                    self?.metadata.showNoValidSource = (sigState == .lost)
                }
            },
            onTimecode: { [weak self] timecode in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    let now = CFAbsoluteTimeGetCurrent()
                    guard now - self.metadata.lastTimecodeUIUpdateTime >= self.metadata.timecodeUIUpdateInterval else { return }
                    self.metadata.lastTimecodeUIUpdateTime = now
                    self.metadata.currentTimecode = timecode.timecodeString
                }
            },
            onAncillary: { [weak self] packet in
                self?.handleAncillaryPacket(packet)
            }
        )
        let startOk = session.start()
        // #region agent log
        debugSessionLog(location: "CapturePreviewView.startCapture", message: "session.start() result", data: ["startOk": startOk, "isLive": startOk], hypothesisId: "H3")
        // #endregion
        if startOk {
            captureSession = session
            // Reset primary driver so the new MetalPreviewView (created when isLive
            // toggles from false → true) can register as the driver for processFrame.
            pipeline.resetPrimaryDriver()
            isLive = true
            errorMessage = nil
            HDRLogger.info(category: logCategory, "Capture started device=\(deviceIndex) mode=\(modeIndex)")
        } else {
            errorMessage = "Failed to start capture."
        }
    }

    public func stopCapture() {
        captureSession?.stop()
        captureSession = nil
        isLive = false
        errorMessage = nil
        metadata.reset()
        MetadataPipeline.sharedAlerting = nil
        metadataAlerting.resetGapState()
        ancillaryQueue.async { [weak self] in
            self?.ancillaryPackets.removeAll()
        }
        // Keep last format/frame rate for display until next start
    }

    /// DV-009: Buffer VANC packets and parse DV/HDR10 metadata for the display panel.
    func handleAncillaryPacket(_ packet: AncillaryPacket) {
        ancillaryQueue.async { [weak self] in
            guard let self = self else { return }
            self.ancillaryPackets.append(packet)
            if self.ancillaryPackets.count > self.maxAncillaryPackets {
                self.ancillaryPackets.removeFirst(self.ancillaryPackets.count - self.maxAncillaryPackets)
            }
            let copy = self.ancillaryPackets
            DispatchQueue.main.async {
                self.updateMetadataFromPackets(copy)
            }
        }
    }

    private func updateMetadataFromPackets(_ packets: [AncillaryPacket]) {
        // DV-011: Use alerting path so gap/error are logged to QC; same parse gives us L1/L2 for display.
        MetadataPipeline.sharedAlerting = metadataAlerting
        let rpu = MetadataPipeline.parseDolbyVisionRPUWithAlerting(from: packets, frameIndex: metadataFrameIndex)
        metadataFrameIndex = metadataFrameIndex &+ 1
        if let rpu = rpu {
            metadata.currentDolbyVisionL1 = rpu.level1
            if let l1 = rpu.level1 {
                metadata.l1History.append(l1)
                if metadata.l1History.count > metadata.maxL1HistoryCount {
                    metadata.l1History.removeFirst(metadata.l1History.count - metadata.maxL1HistoryCount)
                }
            }
            metadata.currentDolbyVisionL2 = rpu.level2
        } else {
            metadata.currentDolbyVisionL1 = nil
            metadata.currentDolbyVisionL2 = nil
        }
        if let hdr = MetadataPipeline.parseHDR10Static(from: packets) {
            metadata.currentHDR10Static = hdr
        }
    }

    public var pipelineForDisplay: MasterPipeline? { pipeline }

    /// SC-021: Handle click on video preview — convert view point to texture coords and sample pixel; updates pixelPickerResult.
    /// Accounts for aspect ratio letterboxing when view aspect != video aspect.
    public func handlePixelPick(viewPoint: CGPoint, viewSize: CGSize) {
        guard let pipeline = pipeline,
              let tex = pipeline.displayTexture else {
            pixelPickerResult = nil
            return
        }
        let tw = tex.width
        let th = tex.height
        guard tw > 0, th > 0, viewSize.width > 0, viewSize.height > 0 else { return }
        // Compute letterbox/pillarbox offsets for aspect-correct mapping
        let videoAspect = CGFloat(tw) / CGFloat(th)
        let viewAspect = viewSize.width / viewSize.height
        var contentRect = CGRect(origin: .zero, size: viewSize)
        if videoAspect > viewAspect {
            // Pillarbox (video wider than view) — letterbox top/bottom
            let contentH = viewSize.width / videoAspect
            contentRect = CGRect(x: 0, y: (viewSize.height - contentH) / 2, width: viewSize.width, height: contentH)
        } else {
            // Letterbox (video taller than view) — pillarbox left/right
            let contentW = viewSize.height * videoAspect
            contentRect = CGRect(x: (viewSize.width - contentW) / 2, y: 0, width: contentW, height: viewSize.height)
        }
        // Map view point to texture coords within the content rect
        let normalX = (viewPoint.x - contentRect.origin.x) / contentRect.width
        let normalY = (viewPoint.y - contentRect.origin.y) / contentRect.height
        guard normalX >= 0, normalX <= 1, normalY >= 0, normalY <= 1 else {
            pixelPickerResult = nil
            return
        }
        let px = Int(normalX * CGFloat(tw))
        let py = Int(normalY * CGFloat(th))
        let x = min(max(0, px), tw - 1)
        let y = min(max(0, py), th - 1)
        pipeline.sampleDisplayPixel(x: x, y: y) { [weak self] result in
            guard let self = self else { return }
            if let (r, g, b, a) = result {
                self.pixelPickerResult = PixelPickerResult(x: x, y: y, r: r, g: g, b: b, a: a)
            } else {
                self.pixelPickerResult = nil
            }
        }
    }

    /// UI-009: Sync loaded LUT texture and options to pipeline (CS-012, CS-013). CS-015: Same LUT applied to both display and scope when one is loaded.
    public func syncLUTToPipeline() {
        let tex = lutLoadState.lutTexture
        pipeline?.lutTexture = tex
        pipeline?.displayLUTTexture = tex
        pipeline?.scopeLUTTexture = tex
        pipeline?.lutUseTetrahedral = lutLoadState.useTetrahedralInterpolation
    }
}

// MARK: - Metal preview (MTKView in SwiftUI)

/// MTKView that renders the pipeline's display texture. First view to draw becomes the pipeline driver (processFrame); others only present. Ensures one driver regardless of layout (fixes no image when quadrant 1 is not Video).
public struct MetalPreviewView: NSViewRepresentable {
    let pipeline: MasterPipeline?
    let scope: WaveformScope?
    let histogramScope: HistogramScope?
    var onFrameRendered: (() -> Void)?

    public init(pipeline: MasterPipeline?, scope: WaveformScope? = nil, histogramScope: HistogramScope? = nil, isPrimaryDriver: Bool = true, onFrameRendered: (() -> Void)? = nil) {
        self.pipeline = pipeline
        self.scope = scope
        self.histogramScope = histogramScope
        self.onFrameRendered = onFrameRendered
    }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MetalEngine.shared?.device
        view.delegate = context.coordinator
        view.framebufferOnly = false  // Must be false: blitEncoder.copy() requires non-framebufferOnly destination
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.0, green: 0.6, blue: 0.0, alpha: 1)  // Bright green: proves MTKView is rendering. If you see green, draw() works but blitToDrawable fails.
        view.isPaused = (pipeline == nil)
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        return view
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.pipeline = pipeline
        context.coordinator.scope = scope
        context.coordinator.histogramScope = histogramScope
        context.coordinator.onFrameRendered = onFrameRendered
        nsView.isPaused = (pipeline == nil)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(pipeline: pipeline, scope: scope, histogramScope: histogramScope, onFrameRendered: onFrameRendered)
    }

    public class Coordinator: NSObject, MTKViewDelegate {
        var pipeline: MasterPipeline?
        var scope: WaveformScope?
        var histogramScope: HistogramScope?
        var onFrameRendered: (() -> Void)?

        init(pipeline: MasterPipeline?, scope: WaveformScope?, histogramScope: HistogramScope?, onFrameRendered: (() -> Void)? = nil) {
            self.pipeline = pipeline
            self.scope = scope
            self.histogramScope = histogramScope
            self.onFrameRendered = onFrameRendered
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        private var drawCount = 0

        public func draw(in view: MTKView) {
            drawCount += 1
            guard let drawable = view.currentDrawable else {
                if drawCount <= 3 { NSLog("[MetalPreview] draw #%d: no drawable", drawCount) }
                return
            }
            guard let pipeline = pipeline else {
                if drawCount <= 3 { NSLog("[MetalPreview] draw #%d: no pipeline", drawCount) }
                return
            }
            if drawCount <= 5 {
                NSLog("[MetalPreview] draw #%d: drawable OK, pipeline OK, submittedFrames=%d, displayTex=%@",
                      drawCount, pipeline.submittedFrameCount,
                      pipeline.displayTexture.map { "\($0.width)x\($0.height)" } ?? "nil")
            }
            let drove = pipeline.drawToDrawable(drawable, viewId: ObjectIdentifier(self))
            if drove {
                scope?.update(texture: pipeline.displayTexture)
                histogramScope?.update(texture: pipeline.displayTexture)
            }
        }
    }
}

// MARK: - SC-024: Safe Area / Framing guide overlays

/// Action Safe = 90% of frame (5% inset); Title Safe = 80% of frame (10% inset). Drawn as stroked rectangles; hit-testing disabled so gestures pass through.
private struct SafeAreaGuideOverlay: View {
    var showActionSafe: Bool
    var showTitleSafe: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                if showActionSafe {
                    Rectangle()
                        .stroke(Color.green.opacity(0.9), lineWidth: 1)
                        .frame(width: w * 0.90, height: h * 0.90)
                }
                if showTitleSafe {
                    Rectangle()
                        .stroke(Color.cyan.opacity(0.9), lineWidth: 1)
                        .frame(width: w * 0.80, height: h * 0.80)
                }
            }
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Video-only preview (for quadrants 2–4 when content is Video)

/// Shows only the video preview (live Metal or placeholder). Use in quadrants that display "Video" but not the full capture UI.
/// SC-021: Click on video to show pixel values (pixel picker overlay).
/// Pipeline driver is chosen at runtime (first view to draw); isPrimaryDriver is ignored and kept for API compatibility.
public struct VideoPreviewOnlyView: View {
    @ObservedObject private var state: CapturePreviewState
    private let isPrimaryDriver: Bool

    public init(state: CapturePreviewState, isPrimaryDriver: Bool = false) {
        self._state = ObservedObject(wrappedValue: state)
        self.isPrimaryDriver = isPrimaryDriver
    }

    public var body: some View {
        ZStack {
            if state.isLive, let pipeline = state.pipelineForDisplay {
                MetalPreviewView(pipeline: pipeline, scope: state.scope, histogramScope: state.histogramScope, onFrameRendered: { state.tickTimedScreenshotFrame() })
            } else {
                CapturePlaceholderView()
            }
            SafeAreaGuideOverlay(showActionSafe: state.showActionSafe, showTitleSafe: state.showTitleSafe)
            pixelPickerOverlay
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pixelPickerOverlay: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .frame(width: geo.size.width, height: geo.size.height)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onEnded { value in
                            if abs(value.translation.width) < 2, abs(value.translation.height) < 2 {
                                state.handlePixelPick(viewPoint: value.startLocation, viewSize: geo.size)
                            }
                        }
                )
            if let r = state.pixelPickerResult {
                VStack {
                    Spacer()
                    HStack {
                        PixelPickerHUDView(result: r)
                        Spacer()
                    }
                    .padding(8)
                }
            }
        }
    }
}

// MARK: - Placeholder when not capturing

public struct CapturePlaceholderView: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 12) {
            Text("No signal")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Select a device and display mode, then start capture.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Live indicator

public struct LiveIndicatorView: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text("Live")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(6)
    }
}

// MARK: - Main capture preview

/// Main capture preview: device picker, display mode list, start/stop, and preview area (Metal or placeholder).
public struct CapturePreviewView: View {
    @ObservedObject private var state: CapturePreviewState

    public init(state: CapturePreviewState) {
        self._state = ObservedObject(wrappedValue: state)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Capture")
                    .font(.headline)
                if state.isLive {
                    LiveIndicatorView()
                }
            }

            // Input source panel (UI-007): device + format via DL-001
            InputSourceSelectionPanel(state: state)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pixel format")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $state.selectedPixelFormat) {
                        Text("10-bit YUV (v210)").tag(DeckLinkPixelFormat.v210)
                        Text("12-bit RGB (R12L)").tag(DeckLinkPixelFormat.rgb12BitLE)
                        Text("12-bit RGB (R12B)").tag(DeckLinkPixelFormat.rgb12Bit)
                        Text("8-bit BGRA").tag(DeckLinkPixelFormat.rgb8)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 140)
                }
                .disabled(state.isLive)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Signal Range")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $state.selectedSignalRange) {
                        ForEach(SignalRange.allCases, id: \.self) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(minWidth: 80)
                }
                Button(state.isLive ? "Stop" : "Start") {
                    if state.isLive { state.stopCapture() } else { state.startCapture() }
                }
                .keyboardShortcut(state.isLive ? .cancelAction : .defaultAction)
                Spacer()
                Toggle("Action Safe", isOn: $state.showActionSafe)
                    .toggleStyle(.checkbox)
                Toggle("Title Safe", isOn: $state.showTitleSafe)
                    .toggleStyle(.checkbox)
            }

            if let msg = state.errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if state.metadata.showNoValidSource && state.isLive {
                Text("No valid source")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Preview area (SC-021: click to show pixel values; SC-024: Action/Title Safe overlays)
            ZStack {
                if state.isLive, let pipeline = state.pipelineForDisplay {
                    MetalPreviewView(pipeline: pipeline, scope: state.scope, histogramScope: state.histogramScope, onFrameRendered: { state.tickTimedScreenshotFrame() })
                } else {
                    CapturePlaceholderView()
                }
                SafeAreaGuideOverlay(showActionSafe: state.showActionSafe, showTitleSafe: state.showTitleSafe)
                pixelPickerOverlay
                // Diagnostic overlay: shows frame counters while live. Remove after debugging.
                if state.isLive, let pipeline = state.pipelineForDisplay {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack {
                            HStack {
                                Text("Submitted: \(pipeline.submittedFrameCount)  Draw: \(pipeline.totalDrawCalls)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.yellow)
                                    .padding(4)
                                    .background(Color.black.opacity(0.7))
                                    .cornerRadius(4)
                                Spacer()
                            }
                            .padding(6)
                            Spacer()
                        }
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(minHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding()
        .onAppear {
            state.startDeviceNotifications()
            state.refreshDevices(mergeFromIterator: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: DeckLinkDeviceManager.deckLinkDeviceListDidChangeNotification)) { _ in
            state.refreshDevices()
        }
    }

    private var pixelPickerOverlay: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .frame(width: geo.size.width, height: geo.size.height)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onEnded { value in
                            if abs(value.translation.width) < 2, abs(value.translation.height) < 2 {
                                state.handlePixelPick(viewPoint: value.startLocation, viewSize: geo.size)
                            }
                        }
                )
            if let r = state.pixelPickerResult {
                VStack {
                    Spacer()
                    HStack {
                        PixelPickerHUDView(result: r)
                        Spacer()
                    }
                    .padding(8)
                }
            }
        }
    }
}
