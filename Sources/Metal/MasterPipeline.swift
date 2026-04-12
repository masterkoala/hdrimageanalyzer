import Foundation
import Metal
import QuartzCore
import CoreGraphics
import ImageIO
import Logging
import Common

/// A captured frame with a GPU texture, used by MasterPipeline for processing.
public struct Frame {
    /// The Metal texture backing this frame.
    public let texture: MTLTexture
    /// Width of the frame in pixels.
    public var width: Int { texture.width }
    /// Height of the frame in pixels.
    public var height: Int { texture.height }

    public init(texture: MTLTexture) {
        self.texture = texture
    }
}

/// bmdFormat10BitYUV (v210) FourCC — used to select v210 convert path in processFrame().
private let kPixelFormatV210: FramePixelFormat = 0x76323130  // 'v210'
/// bmdFormat12BitRGBLE (R12L) FourCC — 12-bit RGB 4:4:4 little-endian. DL-015.
private let kPixelFormatR12L: FramePixelFormat = 0x5231324C  // 'R12L'
/// 32-bit BGRA (CVPixelBuffer from IDeckLinkMacVideoBuffer). Used when bridge delivers CVPixelBuffer.
private let kPixelFormatBGRA: FramePixelFormat = 0x42475241  // 'BGRA'

/// Scope types that can be selectively enabled/disabled for performance.
public enum ScopeType: Hashable, CaseIterable {
    case waveform, vectorscope, parade, ciexy, histogram
}

/// MT-004: Master render pipeline — Capture -> Convert (v210 to RGB or placeholder) -> Scopes -> Display.
/// Integrates with Capture via MetalEngine.shared.frameManager.submitFrame(); pipeline consumes via processFrame().
public final class MasterPipeline {
    private let engine: MetalEngine
    private let logCategory = "Metal.Pipeline"
    private let lock = NSLock()
    /// First view that calls drawToDrawable becomes the driver (processFrame). Call from main thread only. Ensures exactly one view drives even when layout has no "primary" (e.g. quadrant 1 = Waveform).
    private var primaryDriverId: ObjectIdentifier?
    /// INT-003: Serial queue for processFrame so main thread only blits (avoids UI freeze). Main sets processing = true when dispatching and clears in completion.
    private let processQueue = DispatchQueue(label: "Metal.Pipeline.process", qos: .userInteractive)
    private var processing = false

    private var convertV210PipelineState: MTLComputePipelineState?
    private var convertBGRAPipelineState: MTLComputePipelineState?
    private var convertR12LPipelineState: MTLComputePipelineState?

    /// Render pipeline for fullscreen quad blit (copy_vertex + copy_fragment). Works with any drawable.
    private var copyRenderPipelineState: MTLRenderPipelineState?

    /// Persistent V210Params buffer for compute kernel (width, height, rowBytes).
    private var v210ParamsBuffer: MTLBuffer?
    /// Persistent signal-range buffer (single uint32: 0=full, 1=legal).
    private var signalRangeBuffer: MTLBuffer?

    // For performance monitoring
    private var frameCount = 0
    private var lastFrameTime = CFAbsoluteTimeGetCurrent()
    private var drawCallCount = 0
    /// Last time we printed a heartbeat log (every ~5s while drawing).
    private var lastHeartbeatTime: CFAbsoluteTime = 0

    /// Public frame counter: number of frames submitted via submitFrame(). Read from UI for diagnostics.
    public var submittedFrameCount: Int { frameCount }
    /// Public draw call counter.
    public var totalDrawCalls: Int { drawCallCount }

    // MARK: - Properties referenced by CapturePreviewView

    /// Signal range flag for YCbCr→RGB conversion (0 = full, 1 = legal). Set from CapturePreviewState.selectedSignalRange.shaderValue.
    public var signalRange: UInt32 = 0

    /// The current display texture produced by processFrame; read by scope views and pixel picker.
    public var displayTexture: MTLTexture? {
        return _latestTexture
    }

    /// UI-009 / CS-012: 3D LUT texture for pipeline colour transform.
    public var lutTexture: MTLTexture?
    /// CS-015: LUT texture applied to display output.
    public var displayLUTTexture: MTLTexture?
    /// CS-015: LUT texture applied to scope output.
    public var scopeLUTTexture: MTLTexture?
    /// CS-013: When true, use tetrahedral interpolation for LUT; otherwise trilinear.
    public var lutUseTetrahedral: Bool = false

    // MARK: - Scope parameters (synced from SharedAppState)

    /// Per-scope gamma/gain for brightness/contrast adjustment in scope rendering.
    /// Gamma < 1 compresses highlights and lifts shadows for better low-density visibility.
    /// Gain multiplies the final intensity for overall brightness.
    public var waveformGamma: Float = 0.40
    public var waveformGain: Float = 1.5
    public var vectorscopeGamma: Float = 0.40
    public var vectorscopeGain: Float = 1.5
    public var paradeGamma: Float = 0.40
    public var paradeGain: Float = 1.5
    public var ciexyGamma: Float = 0.40
    public var ciexyGain: Float = 1.5

    /// Histogram overlay / stacked / parade mode.
    public var histogramDisplayMode: HistogramDisplayMode = .overlay

    /// Set of currently enabled scope types — scopes not in this set can skip rendering.
    public var enabledScopes: Set<ScopeType> = Set(ScopeType.allCases)

    public init(engine: MetalEngine) {
        self.engine = engine
        setupPipelines()
        setupScopePipelines()
    }

    /// Convenience initialiser used by CapturePreviewState: accepts nil and falls back to MetalEngine.shared.
    /// Returns nil when no Metal device is available.
    public convenience init?(engine: MetalEngine?) {
        if let engine = engine {
            self.init(engine: engine)
        } else if let shared = MetalEngine.shared {
            self.init(engine: shared)
        } else {
            return nil
        }
    }

    private func setupPipelines() {
        guard let library = engine.library else {
            HDRLogger.error(category: logCategory, message: "Failed to get Metal library for pipeline setup")
            return
        }

        // v210 → RGB compute kernel (embedded in MetalEngine)
        if let fn = library.makeFunction(name: "convert_v210_to_rgb") {
            do {
                convertV210PipelineState = try engine.device.makeComputePipelineState(function: fn)
                HDRLogger.info(category: logCategory, message: "v210 conversion pipeline ready")
            } catch {
                HDRLogger.error(category: logCategory, message: "Failed to create v210 pipeline: \(error)")
            }
        } else {
            HDRLogger.warning(category: logCategory, message: "convert_v210_to_rgb function not found in library")
        }

        // BGRA → RGB compute kernel (embedded in MetalEngine)
        if let fn = library.makeFunction(name: "convert_bgra_to_rgb") {
            do {
                convertBGRAPipelineState = try engine.device.makeComputePipelineState(function: fn)
                HDRLogger.info(category: logCategory, message: "BGRA conversion pipeline ready")
            } catch {
                HDRLogger.error(category: logCategory, message: "Failed to create BGRA pipeline: \(error)")
            }
        }

        // R12L → RGB compute kernel (from Shaders/Common/Placeholder.metal if compiled)
        if let fn = library.makeFunction(name: "convert_r12l_to_rgb") {
            do {
                convertR12LPipelineState = try engine.device.makeComputePipelineState(function: fn)
                HDRLogger.info(category: logCategory, message: "R12L conversion pipeline ready")
            } catch {
                HDRLogger.error(category: logCategory, message: "Failed to create R12L pipeline: \(error)")
            }
        }

        // Allocate persistent signal-range buffer (1 × uint32)
        signalRangeBuffer = engine.device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared)

        // Set up fullscreen quad render pipeline (copy_vertex + copy_fragment) for blitting to drawables.
        if let vtxFn = library.makeFunction(name: "copy_vertex"),
           let fragFn = library.makeFunction(name: "copy_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtxFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            do {
                copyRenderPipelineState = try engine.device.makeRenderPipelineState(descriptor: desc)
            } catch {
                HDRLogger.error(category: logCategory, message: "Failed to create copy render pipeline: \(error)")
            }
        }

        NSLog("[Pipeline] setupPipelines complete: v210=%d bgra=%d r12l=%d copyRender=%d",
              convertV210PipelineState != nil ? 1 : 0,
              convertBGRAPipelineState != nil ? 1 : 0,
              convertR12LPipelineState != nil ? 1 : 0,
              copyRenderPipelineState != nil ? 1 : 0)
        HDRLogger.info(category: logCategory, message: "Pipeline setup complete: v210=\(convertV210PipelineState != nil) bgra=\(convertBGRAPipelineState != nil) r12l=\(convertR12LPipelineState != nil) copyRender=\(copyRenderPipelineState != nil)")
    }

    // MARK: - Frame conversion (raw bytes → RGBA texture)

    /// Convert a FrameSlot (raw bytes in MTLBuffer) to an RGBA texture using the appropriate compute kernel.
    /// Returns the output texture or nil on failure.
    private func convertSlotToTexture(_ slot: FrameSlot) -> MTLTexture? {
        let width = slot.width
        let height = slot.height
        guard width > 0, height > 0 else { return nil }

        // Get or create output texture from pool
        guard let outTexture = engine.texturePool.getTexture(
            width: width, height: height, format: .bgra8Unorm,
            usage: [.shaderRead, .shaderWrite]
        ) else {
            HDRLogger.error(category: logCategory, message: "Failed to get output texture \(width)×\(height)")
            return nil
        }

        // BGRA fast path: direct CPU upload when full range (no conversion needed).
        // When legal range is selected, must use compute kernel for 16-235 → 0-255 expansion.
        if slot.pixelFormat == kPixelFormatBGRA && signalRange == 0 {
            let srcPtr = slot.buffer.contents()
            let region = MTLRegionMake2D(0, 0, width, height)
            outTexture.replace(region: region, mipmapLevel: 0, withBytes: srcPtr, bytesPerRow: slot.rowBytes)
            return outTexture
        }

        // Compute kernel path for v210, R12L, and other formats
        guard let commandBuffer = engine.commandQueue.makeCommandBuffer() else {
            HDRLogger.error(category: logCategory, message: "Failed to create command buffer for frame conversion")
            return nil
        }

        // Update signal range buffer
        if let srBuf = signalRangeBuffer {
            srBuf.contents().storeBytes(of: signalRange, as: UInt32.self)
        }

        // Build V210Params struct: { width, height, rowBytes } (3 × uint32)
        let paramsSize = MemoryLayout<UInt32>.size * 3
        if v210ParamsBuffer == nil || v210ParamsBuffer!.length < paramsSize {
            v210ParamsBuffer = engine.device.makeBuffer(length: paramsSize, options: .storageModeShared)
        }
        if let pb = v210ParamsBuffer {
            let ptr = pb.contents().bindMemory(to: UInt32.self, capacity: 3)
            ptr[0] = UInt32(width)
            ptr[1] = UInt32(height)
            ptr[2] = UInt32(slot.rowBytes)
        }

        // Choose pipeline by pixel format
        let pipelineState: MTLComputePipelineState?
        switch slot.pixelFormat {
        case kPixelFormatV210:
            pipelineState = convertV210PipelineState
        case kPixelFormatR12L:
            pipelineState = convertR12LPipelineState
        case kPixelFormatBGRA:
            pipelineState = convertBGRAPipelineState
        default:
            pipelineState = convertV210PipelineState
        }

        guard let pipeline = pipelineState else {
            HDRLogger.error(category: logCategory, message: "No conversion pipeline for format 0x\(String(slot.pixelFormat, radix: 16))")
            return nil
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(slot.buffer, offset: 0, index: 0)          // raw bytes
        encoder.setBuffer(v210ParamsBuffer, offset: 0, index: 1)     // params {w, h, rowBytes}
        encoder.setBuffer(signalRangeBuffer, offset: 0, index: 2)    // signal range
        encoder.setTexture(outTexture, index: 0)                      // output RGBA

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            HDRLogger.error(category: logCategory, message: "GPU command buffer error: \(commandBuffer.error?.localizedDescription ?? "unknown")")
            return nil
        }

        return outTexture
    }

    // MARK: - Scope Configuration Properties

    /// Waveform display mode (luminance, RGB overlay, YCbCr, etc.)
    public var waveformMode: WaveformMode = .luminance
    /// Maximum nits value for waveform scale (100 for SDR IRE, 10000 for HDR PQ).
    public var waveformMaxNits: Int = 100
    /// Whether to use logarithmic Y-axis scale on waveform.
    public var waveformLogScale: Bool = false
    /// Whether to use single scan-line mode on waveform.
    public var waveformSingleLineMode: Bool = false

    /// The latest processed texture available for scope rendering.
    private var _latestTexture: MTLTexture?

    // MARK: - Scope Offscreen Rendering State (Accumulation-Based)

    /// Queue for async scope texture computation (doesn't block main thread or processQueue).
    private let scopeQueue = DispatchQueue(label: "Metal.Pipeline.scopes", qos: .userInteractive)

    /// Double-buffered scope output textures — alternated each frame for pointer-change detection in ScopeDisplayLayerView.
    private var _scopeOutputTextures: [ScopeType: [MTLTexture]] = [:]
    private var _scopeWriteIdx: Int = 0

    /// Current scope textures (point to the last-rendered target). Read by ScopeDisplayLayerView via scopeTexture(for:).
    /// Protected by scopeTextureLock for thread-safe access between GPU completion handler and display link threads.
    private var _currentScopeTextures: [ScopeType: MTLTexture] = [:]
    private let scopeTextureLock = NSLock()

    // Dynamic scope dimensions — match input resolution for 1:1 pixel mapping
    private var scopeWidth: Int = 0      // matches inputW (waveform, parade)
    private var scopeHeight: Int = 0     // matches inputH (waveform, parade)
    private var scopeSquareSize: Int = 0 // max(inputW, inputH) for vectorscope, CIE

    // Accumulation-based scope pipeline states (from MetalEngine library)
    private var wfRasterizerState: MTLComputePipelineState?
    private var wfResolveState: MTLComputePipelineState?
    private var vecRasterizerState: MTLComputePipelineState?
    private var vecResolveState: MTLComputePipelineState?
    private var paradeRasterizerState: MTLComputePipelineState?
    private var paradeResolveState: MTLComputePipelineState?

    // Accumulation buffers (storageModePrivate; reset via blit fill, atomic writes from compute)
    private var wfAccumBuf: ScopeAccumulationBuffer?
    private var vecAccumBuf: ScopeAccumulationBuffer?
    private var paradeAccumBuf: ScopeAccumulationBuffer?
    private var cieAccumBuf: ScopeAccumulationBuffer?

    // CIE chromaticity scope pipeline states
    private var cieRasterizerState: MTLComputePipelineState?
    private var cieResolveState: MTLComputePipelineState?

    // Blur post-processing for phosphor glow
    private var blurPipelineState: MTLComputePipelineState?
    private var _scopeScratchTextures: [ScopeType: MTLTexture] = [:]

    // Frame-dropping flag: skip scope computation if previous frame still rendering
    private var _scopeRendering = false

    // Histogram scope compute/render pipeline states (from inline MSL)
    private var scopeHistClearState: MTLComputePipelineState?
    private var scopeHistCountState: MTLComputePipelineState?
    private var scopeHistNormalizeState: MTLComputePipelineState?
    private var scopeHistRenderState: MTLRenderPipelineState?
    private var scopeHistAccumBuffer: MTLBuffer?
    private var scopeHistVertexBuffer: MTLBuffer?
    private let kScopeHistBins = 256

    /// Returns the scope texture for the given scope type. Used by ScopeDisplayLayerView.
    /// Thread-safe: called from display link threads concurrently with GPU completion handler writes.
    public func scopeTexture(for scopeType: ScopeType) -> MTLTexture? {
        scopeTextureLock.lock()
        let tex = _currentScopeTextures[scopeType]
        scopeTextureLock.unlock()
        return tex
    }

    /// Sets the latest texture (called after processFrame succeeds).
    public func setLatestTexture(_ texture: MTLTexture?) {
        _latestTexture = texture
    }

    // MARK: - Scope Presentation (Blit to Drawable)

    /// Present the waveform scope output to the given drawable.
    public func presentScopeToDrawable(_ drawable: CAMetalDrawable) {
        guard let texture = scopeTexture(for: .waveform) else { return }
        blitToDrawable(source: texture, drawable: drawable)
    }

    /// Present vectorscope output to the given drawable.
    public func presentVectorscopeToDrawable(_ drawable: CAMetalDrawable) {
        guard let texture = scopeTexture(for: .vectorscope) else { return }
        blitToDrawable(source: texture, drawable: drawable)
    }

    /// Present CIE chromaticity scope output to the given drawable.
    public func presentCieChromaticityToDrawable(_ drawable: CAMetalDrawable) {
        guard let texture = scopeTexture(for: .ciexy) else { return }
        blitToDrawable(source: texture, drawable: drawable)
    }

    /// Present histogram scope output to the given drawable.
    public func presentHistogramToDrawable(_ drawable: CAMetalDrawable) {
        guard let texture = scopeTexture(for: .histogram) else { return }
        blitToDrawable(source: texture, drawable: drawable)
    }

    /// Present RGB parade scope output to the given drawable.
    public func presentParadeToDrawable(_ drawable: CAMetalDrawable) {
        guard let texture = scopeTexture(for: .parade) else { return }
        blitToDrawable(source: texture, drawable: drawable)
    }

    /// Present a cleared drawable (diagnostic green) when no texture is available.
    private func presentClearDrawable(_ drawable: CAMetalDrawable) {
        guard let commandBuffer = engine.commandQueue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Blit call counter for diagnostics.
    private var blitCallCount = 0

    /// Internal blit helper: renders source texture into drawable using a fullscreen quad (handles scaling).
    /// Uses render pass instead of blit encoder for maximum compatibility with drawable textures.
    private func blitToDrawable(source: MTLTexture, drawable: CAMetalDrawable) {
        blitCallCount += 1
        guard let commandBuffer = engine.commandQueue.makeCommandBuffer() else {
            if blitCallCount <= 5 { NSLog("[Pipeline] blitToDrawable: makeCommandBuffer FAILED") }
            return
        }

        // Prefer render-pass approach (works with any drawable, handles scaling via linear sampling)
        if let copyPipeline = copyRenderPipelineState {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
                if blitCallCount <= 5 { NSLog("[Pipeline] blitToDrawable: makeRenderCommandEncoder FAILED") }
                return
            }
            encoder.setRenderPipelineState(copyPipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            if blitCallCount <= 3 {
                NSLog("[Pipeline] blitToDrawable #%d: render pass OK, src=%dx%d dst=%dx%d",
                      blitCallCount, source.width, source.height, drawable.texture.width, drawable.texture.height)
            }
        } else {
            // Fallback: blit encoder (requires framebufferOnly = false)
            if blitCallCount <= 3 { NSLog("[Pipeline] blitToDrawable: using BLIT encoder fallback (no copyRenderPipelineState)") }
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                if blitCallCount <= 5 { NSLog("[Pipeline] blitToDrawable: makeBlitCommandEncoder FAILED") }
                return
            }
            let destTexture = drawable.texture
            let copyWidth = min(source.width, destTexture.width)
            let copyHeight = min(source.height, destTexture.height)
            blitEncoder.copy(
                from: source, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                to: destTexture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
        }

        // Add error handler to detect GPU errors
        if blitCallCount <= 5 {
            let callNum = blitCallCount
            commandBuffer.addCompletedHandler { cb in
                if cb.status == .error {
                    NSLog("[Pipeline] blitToDrawable #%d: GPU ERROR: %@", callNum, cb.error?.localizedDescription ?? "unknown")
                } else if callNum <= 3 {
                    NSLog("[Pipeline] blitToDrawable #%d: GPU completed OK (status=%d)", callNum, cb.status.rawValue)
                }
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Capture integration (used by CapturePreviewView)

    /// Submit a raw frame from the capture callback. Copies bytes into triple buffer for later consumption.
    /// Called on the DeckLink SDK callback thread — must be fast.
    public func submitFrame(bytes: UnsafeRawPointer, rowBytes: Int, width: Int, height: Int, pixelFormat: UInt32) {
        engine.frameManager.submitFrame(bytes: bytes, rowBytes: rowBytes, width: width, height: height, pixelFormat: pixelFormat)
        frameCount += 1
        if frameCount <= 5 || frameCount % 300 == 0 {
            NSLog("[Pipeline] submitFrame #%d: %dx%d rowBytes=%d pf=0x%X", frameCount, width, height, rowBytes, pixelFormat)
        }
    }

    /// Reset the primary driver so the next MetalPreviewView that calls drawToDrawable becomes the new driver.
    /// Called when capture restarts (isLive toggles false -> true) so the freshly-created view can drive.
    public func resetPrimaryDriver() {
        lock.lock()
        primaryDriverId = nil
        lock.unlock()
    }

    /// Draw the display texture into the given CAMetalDrawable. The first view (identified by viewId) to call this
    /// becomes the pipeline driver — subsequent views with a different viewId only blit.
    /// - Parameters:
    ///   - drawable: The drawable to present into.
    ///   - viewId: Unique identifier for the calling view (e.g. ObjectIdentifier(self)).
    /// - Returns: true if this call drove processFrame (primary driver), false if it only blitted.
    @discardableResult
    public func drawToDrawable(_ drawable: CAMetalDrawable, viewId: ObjectIdentifier) -> Bool {
        drawCallCount += 1
        lock.lock()
        if primaryDriverId == nil {
            primaryDriverId = viewId
        }
        let isPrimary = (primaryDriverId == viewId)
        lock.unlock()

        if drawCallCount <= 5 {
            NSLog("[Pipeline] drawToDrawable #%d: isPrimary=%d submittedFrames=%d latestTex=%@",
                  drawCallCount, isPrimary ? 1 : 0, frameCount,
                  _latestTexture.map { "\($0.width)x\($0.height)" } ?? "nil")
        }
        // Heartbeat: log state every ~5 seconds
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastHeartbeatTime > 5.0 {
            lastHeartbeatTime = now
            NSLog("[Pipeline] HEARTBEAT: drawCalls=%d submittedFrames=%d latestTex=%@ processing=%d copyRender=%d",
                  drawCallCount, frameCount,
                  _latestTexture.map { "\($0.width)x\($0.height)" } ?? "nil",
                  processing ? 1 : 0,
                  copyRenderPipelineState != nil ? 1 : 0)
        }

        // INT-003: Primary driver converts frames and updates _latestTexture.
        // BGRA: synchronous on main thread (just CPU memcpy via texture.replace — ~1ms for 1080p).
        // v210/R12L: async on processQueue (requires GPU compute + waitUntilCompleted).
        if isPrimary {
            lock.lock()
            let isProcessing = processing
            lock.unlock()

            if !isProcessing, let slot = engine.frameManager.getLatestFrame() {
                if drawCallCount <= 10 {
                    NSLog("[Pipeline] drawToDrawable: got frame slot %dx%d pf=0x%X",
                          slot.width, slot.height, slot.pixelFormat)
                }

                if slot.pixelFormat == kPixelFormatBGRA {
                    // BGRA fast path: synchronous on main thread (CPU memcpy only, no GPU compute)
                    if let tex = convertSlotToTexture(slot) {
                        _latestTexture = tex
                        // Trigger async scope computation for waveform/histogram
                        computeScopesAsync(from: tex)
                        if drawCallCount <= 5 {
                            NSLog("[Pipeline] BGRA sync convert OK: %dx%d", tex.width, tex.height)
                        }
                    } else if drawCallCount <= 5 {
                        NSLog("[Pipeline] BGRA sync convert FAILED for slot %dx%d", slot.width, slot.height)
                    }
                } else {
                    // v210/R12L: async on processQueue (GPU compute + waitUntilCompleted)
                    lock.lock()
                    processing = true
                    lock.unlock()

                    let convertCount = frameCount
                    processQueue.async { [weak self] in
                        guard let self = self else { return }
                        if let tex = self.convertSlotToTexture(slot) {
                            self._latestTexture = tex
                            // Trigger async scope computation for waveform/histogram
                            self.computeScopesAsync(from: tex)
                            if convertCount <= 5 {
                                NSLog("[Pipeline] v210/R12L async convert OK: %dx%d format=%d", tex.width, tex.height, tex.pixelFormat.rawValue)
                            }
                        } else if convertCount <= 5 {
                            NSLog("[Pipeline] v210/R12L async convert FAILED for slot %dx%d pf=0x%X", slot.width, slot.height, slot.pixelFormat)
                        }
                        self.lock.lock()
                        self.processing = false
                        self.lock.unlock()
                    }
                }
            } else if _latestTexture == nil && !isProcessing {
                // No frames received yet — generate a color-bars test pattern so we know
                // the rendering pipeline is working. If you see color bars, the issue is
                // that DeckLink frames are not reaching submitFrame().
                NSLog("[Pipeline] No frames yet and no latestTexture — generating test pattern")
                if _testPatternTexture == nil {
                    _testPatternTexture = generateTestPattern(width: 640, height: 360)
                    NSLog("[Pipeline] Test pattern generated: %@", _testPatternTexture.map { "\($0.width)x\($0.height)" } ?? "FAILED")
                }
                if let tp = _testPatternTexture {
                    _latestTexture = tp
                }
            }
        }

        // All views blit the display texture to their drawable.
        if let tex = displayTexture {
            blitToDrawable(source: tex, drawable: drawable)
            if drawCallCount <= 5 {
                NSLog("[Pipeline] blitToDrawable called with %dx%d texture", tex.width, tex.height)
            }
        } else {
            // Even with no texture, present the drawable so MTKView doesn't show stale content.
            // The clear color (green) serves as a diagnostic — if user sees green, draw works but no texture.
            presentClearDrawable(drawable)
            if drawCallCount <= 5 {
                NSLog("[Pipeline] drawToDrawable #%d: NO displayTexture — presented clear drawable (green)", drawCallCount)
            }
        }
        return isPrimary
    }

    /// Cached test pattern texture (generated once).
    private var _testPatternTexture: MTLTexture?

    /// Generate SMPTE-style color bars test pattern.
    private func generateTestPattern(width: Int, height: Int) -> MTLTexture? {
        guard let tex = engine.texturePool.getTexture(
            width: width, height: height, format: .bgra8Unorm,
            usage: [.shaderRead, .shaderWrite]
        ) else { return nil }

        // BGRA color bars: White, Yellow, Cyan, Green, Magenta, Red, Blue
        let bars: [(UInt8, UInt8, UInt8, UInt8)] = [
            (255, 255, 255, 255), // White  (BGRA)
            (0,   255, 255, 255), // Yellow
            (255, 255, 0,   255), // Cyan
            (0,   255, 0,   255), // Green
            (255, 0,   255, 255), // Magenta
            (0,   0,   255, 255), // Red
            (255, 0,   0,   255), // Blue
        ]

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let barWidth = width / bars.count
        for y in 0..<height {
            for x in 0..<width {
                let barIndex = min(x / max(barWidth, 1), bars.count - 1)
                let (b, g, r, a) = bars[barIndex]
                let offset = (y * width + x) * 4
                pixels[offset + 0] = b
                pixels[offset + 1] = g
                pixels[offset + 2] = r
                pixels[offset + 3] = a
            }
        }

        let region = MTLRegionMake2D(0, 0, width, height)
        tex.replace(region: region, mipmapLevel: 0, withBytes: &pixels, bytesPerRow: width * 4)
        HDRLogger.info(category: logCategory, message: "Test pattern generated \(width)×\(height) — if visible, frames not reaching pipeline")
        return tex
    }

    /// QC-008: Export current display texture to a PNG file.
    /// - Parameter url: Destination file URL for the PNG.
    /// - Returns: true on success, false on failure.
    @discardableResult
    public func exportDisplayScreenshotToPNG(to url: URL) -> Bool {
        guard let texture = displayTexture else {
            HDRLogger.warning(category: logCategory, message: "No display texture to export")
            return false
        }
        let width = texture.width
        let height = texture.height
        let rowBytes = width * 4
        let byteCount = rowBytes * height
        var data = [UInt8](repeating: 0, count: byteCount)
        texture.getBytes(&data, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: rowBytes, space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = ctx.makeImage() else {
            HDRLogger.error(category: logCategory, message: "Failed to create CGImage for PNG export")
            return false
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            HDRLogger.error(category: logCategory, message: "Failed to create image destination for PNG export")
            return false
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        let ok = CGImageDestinationFinalize(dest)
        if ok {
            HDRLogger.info(category: logCategory, message: "Exported display screenshot to \(url.path)")
        } else {
            HDRLogger.error(category: logCategory, message: "CGImageDestinationFinalize failed for PNG export")
        }
        return ok
    }

    /// Capture display texture as CGImage for save/copy operations.
    public func captureDisplayScreenshot() -> CGImage? {
        guard let texture = displayTexture else { return nil }
        return cgImage(from: texture)
    }

    /// Capture scope texture as CGImage for export or Web UI streaming.
    public func captureScopeScreenshot() -> CGImage? {
        guard let texture = displayTexture else { return nil }
        return cgImage(from: texture)
    }

    /// Convert a Metal texture to CGImage.
    private func cgImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let rowBytes = width * 4
        let byteCount = rowBytes * height
        var data = [UInt8](repeating: 0, count: byteCount)
        texture.getBytes(&data, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: rowBytes, space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }

    /// SC-021: Sample a single pixel from the display texture at (x, y). Returns (R, G, B, A) as UInt8 via callback on main thread.
    /// Callback receives nil if the texture is unavailable or coordinates are out of bounds.
    public func sampleDisplayPixel(x: Int, y: Int, completion: @escaping ((UInt8, UInt8, UInt8, UInt8)?) -> Void) {
        guard let texture = displayTexture else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        guard x >= 0, x < texture.width, y >= 0, y < texture.height else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        let result = (pixel[0], pixel[1], pixel[2], pixel[3])
        DispatchQueue.main.async { completion(result) }
    }

    // MARK: - Scope Pipeline Setup & Rendering

    /// Struct matching MSL `ScopeResolveParams { float gamma; float gain; uint useLogScale; }`.
    private struct ScopeResolveParams {
        var gamma: Float
        var gain: Float
        var useLogScale: UInt32
    }

    /// Compiles scope pipeline states. Accumulation buffers and textures are created dynamically
    /// when the first frame arrives (via ensureScopeResources) to match input resolution 1:1.
    private func setupScopePipelines() {
        let device = engine.device

        // Pipeline states from MetalEngine's compiled shader library
        if let fn = engine.makeFunction(name: "scope_point_rasterizer_waveform") {
            wfRasterizerState = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = engine.makeFunction(name: "scope_accumulation_to_texture") {
            wfResolveState = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = engine.makeFunction(name: "scope_point_rasterizer_vectorscope") {
            vecRasterizerState = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = engine.makeFunction(name: "scope_accumulation_to_texture_vectorscope") {
            vecResolveState = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = engine.makeFunction(name: "scope_point_rasterizer_rgb_parade") {
            paradeRasterizerState = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = engine.makeFunction(name: "scope_accumulation_to_texture_parade") {
            paradeResolveState = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = engine.makeFunction(name: "scope_point_rasterizer_cie_xy") {
            cieRasterizerState = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = engine.makeFunction(name: "scope_accumulation_to_texture_cie") {
            cieResolveState = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = engine.makeFunction(name: "scope_texture_blur_5x5") {
            blurPipelineState = try? device.makeComputePipelineState(function: fn)
        }

        // --- Histogram (inline MSL — fixed dimensions, not input-dependent) ---
        let histAccumSize = 4 * kScopeHistBins * MemoryLayout<UInt32>.stride
        scopeHistAccumBuffer = device.makeBuffer(length: histAccumSize, options: .storageModeShared)
        let histVertSize = 4 * kScopeHistBins * MemoryLayout<Float>.stride * 2
        scopeHistVertexBuffer = device.makeBuffer(length: histVertSize, options: .storageModeShared)

        let histLibrary: MTLLibrary?
        do {
            histLibrary = try device.makeLibrary(source: Self.scopeHistogramShaderSource, options: nil)
        } catch {
            NSLog("[Pipeline] HISTOGRAM SHADER COMPILE FAILED: %@", error.localizedDescription)
            histLibrary = nil
        }
        if let library = histLibrary {
            if let fn = library.makeFunction(name: "histogram_clear") {
                scopeHistClearState = try? device.makeComputePipelineState(function: fn)
            }
            if let fn = library.makeFunction(name: "histogram_count_pixels") {
                scopeHistCountState = try? device.makeComputePipelineState(function: fn)
            }
            if let fn = library.makeFunction(name: "histogram_normalize") {
                scopeHistNormalizeState = try? device.makeComputePipelineState(function: fn)
            }
            if let vtx = library.makeFunction(name: "histogram_line_vertex"),
               let frag = library.makeFunction(name: "histogram_line_fragment") {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vtx
                desc.fragmentFunction = frag
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                desc.colorAttachments[0].isBlendingEnabled = true
                desc.colorAttachments[0].rgbBlendOperation = .add
                desc.colorAttachments[0].alphaBlendOperation = .add
                desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                desc.colorAttachments[0].sourceAlphaBlendFactor = .one
                desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                scopeHistRenderState = try? device.makeRenderPipelineState(descriptor: desc)
            }
        }

        NSLog("[Pipeline] setupScopePipelines: wfR=%d wfRes=%d vecR=%d vecRes=%d parR=%d parRes=%d cieR=%d cieRes=%d blur=%d histCl=%d histCo=%d histNo=%d histRe=%d",
              wfRasterizerState != nil ? 1 : 0, wfResolveState != nil ? 1 : 0,
              vecRasterizerState != nil ? 1 : 0, vecResolveState != nil ? 1 : 0,
              paradeRasterizerState != nil ? 1 : 0, paradeResolveState != nil ? 1 : 0,
              cieRasterizerState != nil ? 1 : 0, cieResolveState != nil ? 1 : 0,
              blurPipelineState != nil ? 1 : 0,
              scopeHistClearState != nil ? 1 : 0, scopeHistCountState != nil ? 1 : 0,
              scopeHistNormalizeState != nil ? 1 : 0, scopeHistRenderState != nil ? 1 : 0)
    }

    /// Ensures scope accumulation buffers and output textures match the input dimensions.
    /// Called on first frame and whenever input resolution changes. Creates 1:1 pixel mapping.
    private func ensureScopeResources(inputWidth: Int, inputHeight: Int) {
        guard inputWidth != scopeWidth || inputHeight != scopeHeight else { return }
        scopeWidth = inputWidth
        scopeHeight = inputHeight
        scopeSquareSize = inputHeight  // square scopes use input height (e.g. 1080)

        let device = engine.device

        // Recreate accumulation buffers at input resolution
        wfAccumBuf = engine.makeScopeAccumulationBuffer(width: scopeWidth, height: scopeHeight)
        vecAccumBuf = engine.makeScopeAccumulationBuffer(width: scopeSquareSize, height: scopeSquareSize)
        paradeAccumBuf = engine.makeScopeAccumulationBuffer(width: scopeWidth, height: scopeHeight)
        cieAccumBuf = engine.makeScopeAccumulationBuffer(width: scopeSquareSize, height: scopeSquareSize)

        // Recreate double-buffered output textures and scratch textures
        let scopeConfigs: [(ScopeType, Int, Int)] = [
            (.waveform, scopeWidth, scopeHeight),
            (.vectorscope, scopeSquareSize, scopeSquareSize),
            (.parade, scopeWidth, scopeHeight),
            (.histogram, scopeWidth, scopeHeight),
            (.ciexy, scopeSquareSize, scopeSquareSize),
        ]
        for (scopeType, w, h) in scopeConfigs {
            var textures: [MTLTexture] = []
            for _ in 0..<2 {
                if let tex = makeScopeOutputTexture(device: device, width: w, height: h) {
                    textures.append(tex)
                }
            }
            if textures.count == 2 {
                _scopeOutputTextures[scopeType] = textures
            }
            if scopeType != .histogram {
                if let scratch = makeScopeOutputTexture(device: device, width: w, height: h) {
                    _scopeScratchTextures[scopeType] = scratch
                }
            }
        }

        // Clear current scope textures since buffers changed
        scopeTextureLock.lock()
        _currentScopeTextures.removeAll()
        scopeTextureLock.unlock()

        NSLog("[Scopes] Resized to %dx%d (square=%d) — matching input resolution", scopeWidth, scopeHeight, scopeSquareSize)
    }

    /// Create an offscreen texture for scope output (compute write + shader read + render target).
    private func makeScopeOutputTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        return device.makeTexture(descriptor: desc)
    }

    /// Log counter for scope diagnostics (only first few frames).
    private var scopeLogCount = 0

    /// Dispatch async scope computation on scopeQueue. All scopes are batched into a single
    /// GPU command buffer for performance (one submission instead of N separate waits).
    /// Uses addCompletedHandler for non-blocking GPU wait. Drops frames if previous scope is still rendering.
    private func computeScopesAsync(from source: MTLTexture) {
        // Frame dropping: skip if previous scope computation hasn't finished yet
        guard !_scopeRendering else { return }
        _scopeRendering = true

        let capturedSource = source
        scopeQueue.async { [weak self] in
            guard let self = self else { return }

            // Ensure scope buffers/textures match input resolution (1:1 pixel)
            self.ensureScopeResources(inputWidth: capturedSource.width, inputHeight: capturedSource.height)

            guard let cmdBuf = self.engine.commandQueue.makeCommandBuffer() else {
                self._scopeRendering = false
                return
            }

            self._scopeWriteIdx = 1 - self._scopeWriteIdx
            let writeIdx = self._scopeWriteIdx
            var updated: [ScopeType: MTLTexture] = [:]
            let doLog = self.scopeLogCount < 5
            self.scopeLogCount += 1

            if self.enabledScopes.contains(.waveform) {
                if let tex = self.encodeWaveformScope(into: cmdBuf, from: capturedSource, targetIndex: writeIdx) {
                    updated[.waveform] = tex
                } else if doLog { NSLog("[Scopes] waveform encode FAILED") }
            }
            if self.enabledScopes.contains(.vectorscope) {
                if let tex = self.encodeVectorscopeScope(into: cmdBuf, from: capturedSource, targetIndex: writeIdx) {
                    updated[.vectorscope] = tex
                } else if doLog { NSLog("[Scopes] vectorscope encode FAILED") }
            }
            if self.enabledScopes.contains(.parade) {
                if let tex = self.encodeParadeScope(into: cmdBuf, from: capturedSource, targetIndex: writeIdx) {
                    updated[.parade] = tex
                } else if doLog { NSLog("[Scopes] parade encode FAILED") }
            }
            if self.enabledScopes.contains(.histogram) {
                if let tex = self.encodeHistogramScope(into: cmdBuf, from: capturedSource, targetIndex: writeIdx) {
                    updated[.histogram] = tex
                } else if doLog { NSLog("[Scopes] histogram encode FAILED") }
            }
            if self.enabledScopes.contains(.ciexy) {
                if let tex = self.encodeCIEScope(into: cmdBuf, from: capturedSource, targetIndex: writeIdx) {
                    updated[.ciexy] = tex
                } else if doLog { NSLog("[Scopes] CIE encode FAILED") }
            }

            // Non-blocking GPU completion: update textures and clear rendering flag in handler
            cmdBuf.addCompletedHandler { [weak self] cb in
                guard let self = self else { return }
                if cb.status == .completed {
                    self.scopeTextureLock.lock()
                    for (type, tex) in updated {
                        self._currentScopeTextures[type] = tex
                    }
                    self.scopeTextureLock.unlock()
                } else if doLog {
                    NSLog("[Scopes] command buffer FAILED: %@", cb.error?.localizedDescription ?? "unknown")
                }
                self._scopeRendering = false
            }
            cmdBuf.commit()
        }
    }

    // MARK: - Scope Encode Methods (encode into shared command buffer)

    /// Encode waveform scope: accumulation point rasterization + phosphor color ramp resolve.
    private func encodeWaveformScope(into cmdBuf: MTLCommandBuffer, from source: MTLTexture, targetIndex: Int) -> MTLTexture? {
        guard let targets = _scopeOutputTextures[.waveform], targetIndex < targets.count,
              let accum = wfAccumBuf,
              let rasterizer = wfRasterizerState,
              let resolve = wfResolveState else { return nil }
        let target = targets[targetIndex]

        // Reset accumulation buffer to zero
        accum.reset(commandBuffer: cmdBuf)

        // Point-rasterize: each source pixel increments accum[column][luminance]
        guard let compEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        compEnc.setComputePipelineState(rasterizer)
        accum.bindForCompute(encoder: compEnc, at: 0)
        compEnc.setTexture(source, index: 0)
        var params: [UInt32] = [
            UInt32(scopeWidth),      // accumW
            UInt32(scopeHeight),     // accumH
            UInt32(source.width),       // inputW
            UInt32(source.height),      // inputH
            UInt32(waveformMode.rawValue), // mode
            UInt32(waveformMaxNits),    // maxNits
            0,                          // inputIsPQ
            waveformSingleLineMode ? 1 : 0,  // singleLineMode
            0                           // singleLineRow
        ]
        compEnc.setBytes(&params, length: params.count * MemoryLayout<UInt32>.stride, index: 1)
        let (rGrid, rGroup) = ComputeDispatch.threadgroupsForTexture2D(
            width: source.width, height: source.height, pipeline: rasterizer)
        compEnc.dispatchThreadgroups(rGrid, threadsPerThreadgroup: rGroup)
        compEnc.endEncoding()

        // Resolve accumulation → phosphor-colored output texture (via scratch for blur)
        let resolveTarget = _scopeScratchTextures[.waveform] ?? target
        guard let resolveEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        resolveEnc.setComputePipelineState(resolve)
        accum.bindForCompute(encoder: resolveEnc, at: 0)
        // Scale: with 1:1 resolution, typical hit count per cell is ~1-3 (sparse).
        // Low scale (3.0) ensures even single hits are visible on the phosphor ramp.
        var scale: Float = 3.0
        resolveEnc.setBytes(&scale, length: MemoryLayout<Float>.stride, index: 1)
        var resolveParams = ScopeResolveParams(gamma: waveformGamma, gain: waveformGain, useLogScale: waveformLogScale ? 1 : 0)
        resolveEnc.setBytes(&resolveParams, length: MemoryLayout<ScopeResolveParams>.stride, index: 2)
        resolveEnc.setTexture(resolveTarget, index: 0)
        let (resGrid, resGroup) = ComputeDispatch.threadgroupsForTexture2D(
            width: scopeWidth, height: scopeHeight, pipeline: resolve)
        resolveEnc.dispatchThreadgroups(resGrid, threadsPerThreadgroup: resGroup)
        resolveEnc.endEncoding()

        // Blur pass: scratch → target for phosphor glow
        if resolveTarget !== target {
            encodeBlur(into: cmdBuf, from: resolveTarget, to: target)
        }

        return target
    }

    /// Encode vectorscope: CbCr point rasterization + colorized resolve.
    private func encodeVectorscopeScope(into cmdBuf: MTLCommandBuffer, from source: MTLTexture, targetIndex: Int) -> MTLTexture? {
        guard let targets = _scopeOutputTextures[.vectorscope], targetIndex < targets.count,
              let accum = vecAccumBuf,
              let rasterizer = vecRasterizerState,
              let resolve = vecResolveState else { return nil }
        let target = targets[targetIndex]

        accum.reset(commandBuffer: cmdBuf)

        guard let compEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        compEnc.setComputePipelineState(rasterizer)
        accum.bindForCompute(encoder: compEnc, at: 0)
        compEnc.setTexture(source, index: 0)
        var params: [UInt32] = [UInt32(scopeSquareSize), UInt32(scopeSquareSize)]
        compEnc.setBytes(&params, length: params.count * MemoryLayout<UInt32>.stride, index: 1)
        let (rGrid, rGroup) = ComputeDispatch.threadgroupsForTexture2D(
            width: source.width, height: source.height, pipeline: rasterizer)
        compEnc.dispatchThreadgroups(rGrid, threadsPerThreadgroup: rGroup)
        compEnc.endEncoding()

        let resolveTarget = _scopeScratchTextures[.vectorscope] ?? target
        guard let resolveEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        resolveEnc.setComputePipelineState(resolve)
        accum.bindForCompute(encoder: resolveEnc, at: 0)
        var scale = max(1.0, Float(source.width * source.height) / Float(scopeSquareSize * scopeSquareSize) * 2.5)
        resolveEnc.setBytes(&scale, length: MemoryLayout<Float>.stride, index: 1)
        var resolveParams = ScopeResolveParams(gamma: vectorscopeGamma, gain: vectorscopeGain, useLogScale: 0)
        resolveEnc.setBytes(&resolveParams, length: MemoryLayout<ScopeResolveParams>.stride, index: 2)
        resolveEnc.setTexture(resolveTarget, index: 0)
        let (resGrid, resGroup) = ComputeDispatch.threadgroupsForTexture2D(
            width: scopeSquareSize, height: scopeSquareSize, pipeline: resolve)
        resolveEnc.dispatchThreadgroups(resGrid, threadsPerThreadgroup: resGroup)
        resolveEnc.endEncoding()

        if resolveTarget !== target {
            encodeBlur(into: cmdBuf, from: resolveTarget, to: target)
        }

        return target
    }

    /// Encode RGB parade: side-by-side R/G/B rasterization + tinted phosphor resolve.
    private func encodeParadeScope(into cmdBuf: MTLCommandBuffer, from source: MTLTexture, targetIndex: Int) -> MTLTexture? {
        guard let targets = _scopeOutputTextures[.parade], targetIndex < targets.count,
              let accum = paradeAccumBuf,
              let rasterizer = paradeRasterizerState,
              let resolve = paradeResolveState else {
            if scopeLogCount <= 5 { NSLog("[Scopes] parade: GUARD FAIL tex=%d accum=%d rast=%d res=%d",
                                          _scopeOutputTextures[.parade]?.count ?? -1,
                                          paradeAccumBuf != nil ? 1 : 0,
                                          paradeRasterizerState != nil ? 1 : 0,
                                          paradeResolveState != nil ? 1 : 0) }
            return nil
        }
        let target = targets[targetIndex]

        accum.reset(commandBuffer: cmdBuf)

        guard let compEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        compEnc.setComputePipelineState(rasterizer)
        accum.bindForCompute(encoder: compEnc, at: 0)
        compEnc.setTexture(source, index: 0)
        var params: [UInt32] = [
            UInt32(scopeWidth),
            UInt32(scopeHeight),
            UInt32(source.width),
            UInt32(source.height)
        ]
        compEnc.setBytes(&params, length: params.count * MemoryLayout<UInt32>.stride, index: 1)
        let (rGrid, rGroup) = ComputeDispatch.threadgroupsForTexture2D(
            width: source.width, height: source.height, pipeline: rasterizer)
        compEnc.dispatchThreadgroups(rGrid, threadsPerThreadgroup: rGroup)
        compEnc.endEncoding()

        let resolveTarget = _scopeScratchTextures[.parade] ?? target
        guard let resolveEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        resolveEnc.setComputePipelineState(resolve)
        accum.bindForCompute(encoder: resolveEnc, at: 0)
        var scale: Float = 3.0
        resolveEnc.setBytes(&scale, length: MemoryLayout<Float>.stride, index: 1)
        var resolveParams = ScopeResolveParams(gamma: paradeGamma, gain: paradeGain, useLogScale: 0)
        resolveEnc.setBytes(&resolveParams, length: MemoryLayout<ScopeResolveParams>.stride, index: 2)
        resolveEnc.setTexture(resolveTarget, index: 0)
        let (resGrid, resGroup) = ComputeDispatch.threadgroupsForTexture2D(
            width: scopeWidth, height: scopeHeight, pipeline: resolve)
        resolveEnc.dispatchThreadgroups(resGrid, threadsPerThreadgroup: resGroup)
        resolveEnc.endEncoding()

        if resolveTarget !== target {
            encodeBlur(into: cmdBuf, from: resolveTarget, to: target)
        }

        return target
    }

    /// Encode CIE xy chromaticity: XYZ conversion + point rasterization + white phosphor resolve.
    private func encodeCIEScope(into cmdBuf: MTLCommandBuffer, from source: MTLTexture, targetIndex: Int) -> MTLTexture? {
        guard let targets = _scopeOutputTextures[.ciexy], targetIndex < targets.count,
              let accum = cieAccumBuf,
              let rasterizer = cieRasterizerState,
              let resolve = cieResolveState else { return nil }
        let target = targets[targetIndex]

        accum.reset(commandBuffer: cmdBuf)

        guard let compEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        compEnc.setComputePipelineState(rasterizer)
        accum.bindForCompute(encoder: compEnc, at: 0)
        compEnc.setTexture(source, index: 0)
        var params: [UInt32] = [UInt32(scopeSquareSize), UInt32(scopeSquareSize)]
        compEnc.setBytes(&params, length: params.count * MemoryLayout<UInt32>.stride, index: 1)
        let (rGrid, rGroup) = ComputeDispatch.threadgroupsForTexture2D(
            width: source.width, height: source.height, pipeline: rasterizer)
        compEnc.dispatchThreadgroups(rGrid, threadsPerThreadgroup: rGroup)
        compEnc.endEncoding()

        // Resolve to scratch texture, then blur to final target for phosphor glow
        let resolveTarget = _scopeScratchTextures[.ciexy] ?? target
        guard let resolveEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        resolveEnc.setComputePipelineState(resolve)
        accum.bindForCompute(encoder: resolveEnc, at: 0)
        var scale = max(1.0, Float(source.width * source.height) / Float(scopeSquareSize * scopeSquareSize) * 3.0)
        resolveEnc.setBytes(&scale, length: MemoryLayout<Float>.stride, index: 1)
        var resolveParams = ScopeResolveParams(gamma: ciexyGamma, gain: ciexyGain, useLogScale: 0)
        resolveEnc.setBytes(&resolveParams, length: MemoryLayout<ScopeResolveParams>.stride, index: 2)
        resolveEnc.setTexture(resolveTarget, index: 0)
        let (resGrid, resGroup) = ComputeDispatch.threadgroupsForTexture2D(
            width: scopeSquareSize, height: scopeSquareSize, pipeline: resolve)
        resolveEnc.dispatchThreadgroups(resGrid, threadsPerThreadgroup: resGroup)
        resolveEnc.endEncoding()

        if resolveTarget !== target {
            encodeBlur(into: cmdBuf, from: resolveTarget, to: target)
        }

        return target
    }

    /// Encode a 5x5 Gaussian blur pass: read from source, write to destination.
    /// Used as post-processing on resolved scope textures for professional phosphor glow.
    private func encodeBlur(into cmdBuf: MTLCommandBuffer, from source: MTLTexture, to destination: MTLTexture) {
        guard let blurState = blurPipelineState else { return }
        guard let enc = cmdBuf.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(blurState)
        enc.setTexture(source, index: 0)
        enc.setTexture(destination, index: 1)
        let (grid, group) = ComputeDispatch.threadgroupsForTexture2D(
            width: destination.width, height: destination.height, pipeline: blurState)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        enc.endEncoding()
    }

    /// Encode histogram: clear bins, count pixels, normalize, render filled bars.
    private func encodeHistogramScope(into cmdBuf: MTLCommandBuffer, from source: MTLTexture, targetIndex: Int) -> MTLTexture? {
        guard let targets = _scopeOutputTextures[.histogram], targetIndex < targets.count else {
            if scopeLogCount <= 5 { NSLog("[Scopes] hist: no output textures (count=%d)", _scopeOutputTextures[.histogram]?.count ?? -1) }
            return nil
        }
        guard let clearState = scopeHistClearState,
              let countState = scopeHistCountState,
              let normalizeState = scopeHistNormalizeState,
              let renderState = scopeHistRenderState else {
            if scopeLogCount <= 5 { NSLog("[Scopes] hist: missing pipeline states cl=%d co=%d no=%d re=%d",
                                          scopeHistClearState != nil ? 1 : 0, scopeHistCountState != nil ? 1 : 0,
                                          scopeHistNormalizeState != nil ? 1 : 0, scopeHistRenderState != nil ? 1 : 0) }
            return nil
        }
        guard let accumBuf = scopeHistAccumBuffer,
              let vertBuf = scopeHistVertexBuffer else {
            if scopeLogCount <= 5 { NSLog("[Scopes] hist: missing buffers accum=%d vert=%d",
                                          scopeHistAccumBuffer != nil ? 1 : 0, scopeHistVertexBuffer != nil ? 1 : 0) }
            return nil
        }
        let target = targets[targetIndex]

        let n = kScopeHistBins
        var numBinsU32 = UInt32(n)
        var useLogU32: UInt32 = 1
        let totalBins = 4 * n

        // Step 1: Clear accumulation bins
        guard let clearEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        clearEnc.setComputePipelineState(clearState)
        clearEnc.setBuffer(accumBuf, offset: 0, index: 0)
        clearEnc.setBytes(&numBinsU32, length: MemoryLayout<UInt32>.stride, index: 1)
        let (clearGrid, clearGroup) = ComputeDispatch.threadgroupsForBuffer1D(count: totalBins, pipeline: clearState)
        clearEnc.dispatchThreadgroups(clearGrid, threadsPerThreadgroup: clearGroup)
        clearEnc.endEncoding()

        // Step 2: Count pixels into bins (atomic add per channel)
        guard let countEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        countEnc.setComputePipelineState(countState)
        countEnc.setTexture(source, index: 0)
        let stride = n * MemoryLayout<UInt32>.stride
        countEnc.setBuffer(accumBuf, offset: 0, index: 0)
        countEnc.setBuffer(accumBuf, offset: stride, index: 1)
        countEnc.setBuffer(accumBuf, offset: stride * 2, index: 2)
        countEnc.setBuffer(accumBuf, offset: stride * 3, index: 3)
        countEnc.setBytes(&numBinsU32, length: MemoryLayout<UInt32>.stride, index: 4)
        let (countGrid, countGroup) = ComputeDispatch.threadgroupsForTexture2D(width: source.width, height: source.height, pipeline: countState)
        countEnc.dispatchThreadgroups(countGrid, threadsPerThreadgroup: countGroup)
        countEnc.endEncoding()

        // Step 3: Normalize and generate vertex data
        guard let normEnc = cmdBuf.makeComputeCommandEncoder() else { return nil }
        normEnc.setComputePipelineState(normalizeState)
        normEnc.setBuffer(accumBuf, offset: 0, index: 0)
        normEnc.setBuffer(vertBuf, offset: 0, index: 1)
        normEnc.setBytes(&numBinsU32, length: MemoryLayout<UInt32>.stride, index: 2)
        normEnc.setBytes(&useLogU32, length: MemoryLayout<UInt32>.stride, index: 3)
        normEnc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        normEnc.endEncoding()

        // Step 4: Render filled histogram bars to offscreen texture
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)

        guard let renderEnc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        renderEnc.setRenderPipelineState(renderState)
        renderEnc.setVertexBuffer(vertBuf, offset: 0, index: 0)
        let drawOrder: [Int] = [3, 0, 1, 2]
        for ch in drawOrder {
            var channel = UInt32(ch)
            renderEnc.setVertexBytes(&channel, length: MemoryLayout<UInt32>.stride, index: 1)
            renderEnc.setVertexBytes(&numBinsU32, length: MemoryLayout<UInt32>.stride, index: 2)
            renderEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: n * 2)
        }
        renderEnc.endEncoding()

        return target
    }

    // MARK: - Scope Shader Sources (inline MSL)

    /// Histogram scope shaders: clear bins, count pixels, normalize, render filled bars.
    private static let scopeHistogramShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float kLumR = 0.2126;
    constant float kLumG = 0.7152;
    constant float kLumB = 0.0722;

    kernel void histogram_clear(
        device uint* bins [[buffer(0)]],
        constant uint* numBins [[buffer(1)]],
        uint tid [[thread_position_in_grid]])
    {
        uint n = numBins[0] * 4u;
        if (tid < n) { bins[tid] = 0u; }
    }

    kernel void histogram_count_pixels(
        texture2d<float, access::read> src [[texture(0)]],
        device atomic_uint* rBins [[buffer(0)]],
        device atomic_uint* gBins [[buffer(1)]],
        device atomic_uint* bBins [[buffer(2)]],
        device atomic_uint* lBins [[buffer(3)]],
        constant uint* numBins [[buffer(4)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint n = numBins[0];
        uint w = src.get_width();
        uint h = src.get_height();
        if (gid.x >= w || gid.y >= h) return;
        float4 p = src.read(gid);
        float r = saturate(p.r), g = saturate(p.g), b = saturate(p.b);
        float lum = kLumR * r + kLumG * g + kLumB * b;
        uint ri = min(uint(r * float(n)), n - 1u);
        uint gi = min(uint(g * float(n)), n - 1u);
        uint bi = min(uint(b * float(n)), n - 1u);
        uint li = min(uint(lum * float(n)), n - 1u);
        atomic_fetch_add_explicit(&rBins[ri], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&gBins[gi], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&bBins[bi], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&lBins[li], 1u, memory_order_relaxed);
    }

    kernel void histogram_normalize(
        device const uint* counts [[buffer(0)]],
        device float2* vertices [[buffer(1)]],
        constant uint* numBins [[buffer(2)]],
        constant uint* useLog [[buffer(3)]])
    {
        uint n = numBins[0];
        uint total = n * 4u;
        uint maxCount = 0u;
        for (uint i = 0u; i < total; i++) {
            uint c = counts[i];
            if (c > maxCount) maxCount = c;
        }
        float maxF = max(float(maxCount), 1.0);
        bool logScale = useLog[0] != 0u;
        float scaleDenom = logScale ? log1p(maxF) : maxF;
        for (uint idx = 0u; idx < total; idx++) {
            uint c = counts[idx];
            float y = logScale ? (scaleDenom > 0.0 ? log1p(float(c)) / scaleDenom : 0.0) : (float(c) / scaleDenom);
            uint ch = idx / n;
            uint bin = idx % n;
            float x = (float(bin) + 0.5) / float(n);
            vertices[idx] = float2(x * 2.0 - 1.0, y * 2.0 - 1.0);
        }
    }

    struct HistogramVertexOut { float4 position [[position]]; float4 color; };
    vertex HistogramVertexOut histogram_line_vertex(
        uint vid [[vertex_id]],
        device const float2* vertices [[buffer(0)]],
        constant uint* channel [[buffer(1)]],
        constant uint* numBins [[buffer(2)]])
    {
        uint ch = channel[0];
        uint n = numBins[0];
        uint base = ch * n;
        uint bin = vid / 2u;
        uint isTop = vid % 2u;
        if (bin >= n) bin = n - 1u;
        float2 p = vertices[base + bin];
        HistogramVertexOut o;
        if (isTop != 0u) {
            o.position = float4(p.x, p.y, 0, 1);
        } else {
            o.position = float4(p.x, -1.0, 0, 1);
        }
        float4 baseColor;
        if (ch == 0u) baseColor = float4(0.9, 0.15, 0.15, 1.0);
        else if (ch == 1u) baseColor = float4(0.15, 0.85, 0.15, 1.0);
        else if (ch == 2u) baseColor = float4(0.2, 0.35, 0.95, 1.0);
        else baseColor = float4(0.7, 0.7, 0.7, 1.0);
        if (isTop != 0u) {
            o.color = float4(baseColor.rgb, 0.65);
        } else {
            o.color = float4(baseColor.rgb, 0.25);
        }
        return o;
    }
    fragment float4 histogram_line_fragment(HistogramVertexOut in [[stage_in]]) {
        return in.color;
    }
    """
}