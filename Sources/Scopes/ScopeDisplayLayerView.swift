import SwiftUI
import AppKit
import Metal
import MetalKit
import QuartzCore
import MetalEngine

// PERF-002: Lightweight CAMetalLayer-backed scope display view.
// Uses CVDisplayLink for smooth vsync-driven rendering, throttled to targetFPS.
// Replaces the previous 15fps Timer approach with display-link-driven blit from
// the pipeline's cached scope output textures. Includes frame dropping (skip
// render when texture hasn't changed), aspect-ratio-correct rendering via
// copy_vertex_aspect, and a smooth fade-in on first texture arrival.

/// NSView that hosts a CAMetalLayer for displaying scope textures.
/// Driven by CVDisplayLink throttled to `targetFPS`, blits the cached scope texture
/// to the layer's drawable with aspect-ratio-correct scaling and fade-in transition.
public final class ScopeDisplayLayerView: NSView {
    private var metalLayer: CAMetalLayer!
    private var displayLink: CVDisplayLink?
    private var copyPipelineState: MTLRenderPipelineState?
    private var aspectCopyPipelineState: MTLRenderPipelineState?
    private var metalDevice: MTLDevice?

    // MARK: - Frame dropping state

    /// Pointer value of the last rendered texture, used for frame dropping.
    private var lastRenderedTexturePtr: UnsafeMutableRawPointer?

    // MARK: - Adaptive FPS throttling

    /// Target frames per second for scope rendering. CVDisplayLink callbacks are
    /// skipped when the interval since last render is below `1/targetFPS`.
    /// Automatically adapts between minFPS and maxFPS based on GPU render time.
    var targetFPS: Double = 30.0
    /// Timestamp (in seconds) of the last rendered frame.
    private var lastRenderTime: CFTimeInterval = 0
    /// Adaptive FPS range.
    private let minFPS: Double = 30.0
    private let maxFPS: Double = 60.0
    /// Smoothed GPU render time (exponential moving average) for adaptive scaling.
    private var smoothedRenderTime: CFTimeInterval = 0
    private let renderTimeSmoothingFactor: Double = 0.1

    // MARK: - Fade-in state

    /// Whether the first scope texture has ever been rendered.
    private var hasReceivedFirstTexture: Bool = false
    /// The time (CFAbsoluteTimeGetCurrent) when the first texture arrived.
    private var fadeInStartTime: CFAbsoluteTime = 0
    /// Duration of the fade-in transition in seconds.
    private let fadeInDuration: CFAbsoluteTime = 0.3

    /// The pipeline to read scope textures from.
    var pipeline: MasterPipeline?
    /// Which scope type this view displays.
    var scopeType: ScopeType = .waveform

    override public init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        guard let device = MetalEngine.shared?.device else { return }
        metalDevice = device

        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        // Reduce latency: present immediately when committed.
        metalLayer.displaySyncEnabled = true

        wantsLayer = true
        layer = metalLayer

        setupCopyPipeline(device: device)
        setupAspectCopyPipeline(device: device)
    }

    deinit {
        stopDisplayLink()
    }

    // MARK: - Layout

    public override func layout() {
        super.layout()
        guard let metalLayer = metalLayer else { return }
        metalLayer.frame = bounds
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    // MARK: - Window lifecycle (start/stop display link)

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screen = window?.screen ?? NSScreen.main {
            metalLayer?.contentsScale = screen.backingScaleFactor
        }

        if window != nil {
            startDisplayLink()
        } else {
            // View removed from window — stop the link to save GPU.
            stopDisplayLink()
        }
    }

    // MARK: - CVDisplayLink management

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link = link else { return }

        // The display link callback must be a C function pointer. We pass `self`
        // as the userInfo and dispatch back to the main thread for rendering.
        let opaqueself = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { (_, inNow, inOutputTime, _, _, userInfo) -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<ScopeDisplayLayerView>.fromOpaque(userInfo).takeUnretainedValue()
            view.displayLinkDidFire(now: inNow.pointee)
            return kCVReturnSuccess
        }, opaqueself)

        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    /// Called on the CVDisplayLink thread at display refresh rate.
    /// Throttles to `targetFPS` and dispatches rendering to the main thread.
    private func displayLinkDidFire(now: CVTimeStamp) {
        // Convert CVTimeStamp videoTime to seconds.
        let nowSeconds: CFTimeInterval
        if now.videoTimeScale > 0 {
            nowSeconds = CFTimeInterval(now.videoTime) / CFTimeInterval(now.videoTimeScale)
        } else {
            nowSeconds = CACurrentMediaTime()
        }

        // Throttle: skip if not enough time has passed since last render.
        let minInterval = 1.0 / targetFPS
        guard (nowSeconds - lastRenderTime) >= minInterval else { return }
        lastRenderTime = nowSeconds

        DispatchQueue.main.async { [weak self] in
            self?.refreshDisplay()
        }
    }

    // MARK: - Rendering

    private func refreshDisplay() {
        guard let pipeline = pipeline,
              let source = pipeline.scopeTexture(for: scopeType),
              let metalLayer = metalLayer,
              metalLayer.drawableSize.width > 0 && metalLayer.drawableSize.height > 0 else { return }

        // Frame dropping: skip render if the texture hasn't changed.
        let currentPtr = Unmanaged.passUnretained(source).toOpaque()
        if currentPtr == lastRenderedTexturePtr && hasReceivedFirstTexture {
            // Texture pointer unchanged — no new data, skip this frame.
            // Exception: still render during fade-in to animate opacity.
            let elapsed = CFAbsoluteTimeGetCurrent() - fadeInStartTime
            if elapsed >= fadeInDuration {
                return
            }
        }
        lastRenderedTexturePtr = currentPtr

        // Fade-in tracking.
        if !hasReceivedFirstTexture {
            hasReceivedFirstTexture = true
            fadeInStartTime = CFAbsoluteTimeGetCurrent()
        }

        // Compute fade-in opacity (0 -> 1 over fadeInDuration).
        let fadeElapsed = CFAbsoluteTimeGetCurrent() - fadeInStartTime
        let opacity = Float(min(1.0, fadeElapsed / fadeInDuration))

        guard let drawable = metalLayer.nextDrawable(),
              let cmdBuf = MetalEngine.shared?.commandQueue.makeCommandBuffer() else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)

        guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // Use aspect-correct pipeline if available, otherwise fall back to stretch.
        let usedPipelineState = aspectCopyPipelineState ?? copyPipelineState
        guard let pipelineState = usedPipelineState else { return }

        encoder.setRenderPipelineState(pipelineState)

        // If using the aspect-correct shader, compute and pass scale factors.
        if aspectCopyPipelineState != nil {
            var scale = computeAspectScale(sourceTexture: source, drawableSize: metalLayer.drawableSize)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        }

        encoder.setFragmentTexture(source, index: 0)

        // Set blend color alpha for fade-in. The aspect pipeline uses blendAlpha
        // as the source blend factor, so this controls opacity without a custom shader.
        encoder.setBlendColor(red: 1, green: 1, blue: 1, alpha: opacity)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        cmdBuf.present(drawable)
        let renderStart = CACurrentMediaTime()
        cmdBuf.addCompletedHandler { [weak self] _ in
            let elapsed = CACurrentMediaTime() - renderStart
            self?.updateAdaptiveFPS(renderTime: elapsed)
        }
        cmdBuf.commit()
    }

    /// Updates targetFPS based on measured GPU render time.
    /// If GPU has headroom (<50% of frame budget), ramp up toward 60fps.
    /// If GPU is stressed (>80% of budget), drop toward 30fps.
    /// Hysteresis band between 50-80% keeps FPS stable.
    private func updateAdaptiveFPS(renderTime: CFTimeInterval) {
        smoothedRenderTime = smoothedRenderTime * (1 - renderTimeSmoothingFactor) + renderTime * renderTimeSmoothingFactor
        let currentBudget = 1.0 / targetFPS
        if smoothedRenderTime < currentBudget * 0.5 {
            targetFPS = min(maxFPS, targetFPS + 2.0)
        } else if smoothedRenderTime > currentBudget * 0.8 {
            targetFPS = max(minFPS, targetFPS - 5.0)
        }
    }

    /// Compute aspect-fit scale factors to letterbox/pillarbox the source texture
    /// into the drawable without stretching.
    private func computeAspectScale(sourceTexture: MTLTexture, drawableSize: CGSize) -> SIMD2<Float> {
        let srcAspect = Float(sourceTexture.width) / max(1, Float(sourceTexture.height))
        let dstAspect = Float(drawableSize.width) / max(1, Float(drawableSize.height))

        if srcAspect > dstAspect {
            // Source is wider — pillarbox (fit width, shrink height).
            return SIMD2<Float>(1.0, dstAspect / srcAspect)
        } else {
            // Source is taller — letterbox (fit height, shrink width).
            return SIMD2<Float>(srcAspect / dstAspect, 1.0)
        }
    }

    // MARK: - Pipeline setup

    private func setupCopyPipeline(device: MTLDevice) {
        guard let library = MetalEngine.shared?.library else { return }
        guard let vtx = library.makeFunction(name: "copy_vertex"),
              let frag = library.makeFunction(name: "copy_fragment") else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vtx
        desc.fragmentFunction = frag
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        copyPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
    }

    private func setupAspectCopyPipeline(device: MTLDevice) {
        guard let library = MetalEngine.shared?.library else { return }
        guard let vtx = library.makeFunction(name: "copy_vertex_aspect"),
              let frag = library.makeFunction(name: "copy_fragment") else { return }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vtx
        desc.fragmentFunction = frag
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Enable alpha blending for fade-in. Uses blendAlpha (from setBlendColor)
        // to modulate the fragment output against the clear color background.
        // This avoids needing a custom fragment shader — the existing copy_fragment
        // returns full-alpha colors, and the blend color alpha acts as the opacity.
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .blendAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusBlendAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .blendAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusBlendAlpha

        aspectCopyPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
    }
}

// MARK: - SwiftUI NSViewRepresentable

/// Generic scope display representable — works for all scope types via ScopeType enum.
public struct ScopeDisplayRepresentable: NSViewRepresentable {
    let pipeline: MasterPipeline?
    let scopeType: ScopeType

    public init(pipeline: MasterPipeline?, scopeType: ScopeType) {
        self.pipeline = pipeline
        self.scopeType = scopeType
    }

    public func makeNSView(context: Context) -> ScopeDisplayLayerView {
        let view = ScopeDisplayLayerView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.pipeline = pipeline
        view.scopeType = scopeType
        return view
    }

    public func updateNSView(_ nsView: ScopeDisplayLayerView, context: Context) {
        nsView.pipeline = pipeline
        nsView.scopeType = scopeType
    }
}
