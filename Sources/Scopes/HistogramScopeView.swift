import SwiftUI
import AppKit
import Metal
import MetalKit
import Logging
import MetalEngine

// MARK: - Histogram scope model (SC-009)

/// Histogram scope: R/G/B/Luma bins (256 or 1024), linear/log scale. Receives texture via update(texture:).
public final class HistogramScope: ScopeTextureUpdatable {
    public private(set) var currentTexture: MTLTexture?

    public init() {}

    public func update(texture: MTLTexture?) {
        currentTexture = texture
    }
}

// MARK: - Bin count and scale

public enum HistogramBinCount: Int, CaseIterable {
    case bins256 = 256
    case bins1024 = 1024
}

public enum HistogramScale: String, CaseIterable {
    case linear
    case log
}

// MARK: - MTKView: compute bins from texture, render bars/curve

/// Metal view: computes R/G/B/Luma histograms from input texture (MTLBuffer accumulation), renders as curve or bars.
public final class HistogramScopeMTKView: MTKView {
    public weak var scope: HistogramScope?
    /// When set, draw() uses pipeline scope output; otherwise computes from scope.currentTexture.
    public var scopePipeline: MasterPipeline? {
        didSet { if scopePipeline != nil { isPaused = false } }
    }

    /// Number of bins per channel (256 or 1024).
    public var binCount: HistogramBinCount = .bins256 {
        didSet { if binCount != oldValue { needsRebuildBuffers = true } }
    }
    /// Display scale for bin heights.
    public var scale: HistogramScale = .log {
        didSet { needsRedraw = true }
    }

    private var histogramComputePipelineState: MTLComputePipelineState?
    private var histogramClearPipelineState: MTLComputePipelineState?
    private var histogramNormalizePipelineState: MTLComputePipelineState?
    private var histogramLinePipelineState: MTLRenderPipelineState?
    private var binCountBuffer: MTLBuffer?
    private var vertexBuffer: MTLBuffer?
    /// One buffer: 4 channels × binCount × sizeof(uint32). Cleared each frame; atomic add in compute.
    private var accumulationBuffer: MTLBuffer?
    private var placeholderPipelineState: MTLRenderPipelineState?
    private var needsRebuildBuffers = true
    private var needsRedraw = true
    private let logCategory = "Scopes.Histogram"

    /// Total bins = 4 * binCount (R, G, B, Luma).
    private var totalBins: Int { 4 * binCount.rawValue }

    override public init(frame frameRect: CGRect, device: MTLDevice?) {
        let dev = device ?? MetalEngine.shared?.device
        super.init(frame: frameRect, device: dev)
        commonInit()
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        guard let dev = device else { return }
        clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false  // Must be false: scopePipeline uses blitEncoder.copy() to drawable
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = false
        isPaused = false
        delegate = self
        setupPipelines(device: dev)
        rebuildBuffers(device: dev)
    }

    private func setupPipelines(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: Self.histogramShaderSource, options: nil) else {
            return
        }
        if let clearFn = library.makeFunction(name: "histogram_clear") {
            histogramClearPipelineState = try? device.makeComputePipelineState(function: clearFn)
        }
        if let computeFn = library.makeFunction(name: "histogram_count_pixels") {
            histogramComputePipelineState = try? device.makeComputePipelineState(function: computeFn)
        }
        if let normFn = library.makeFunction(name: "histogram_normalize") {
            histogramNormalizePipelineState = try? device.makeComputePipelineState(function: normFn)
        }
        if let vtxFn = library.makeFunction(name: "histogram_line_vertex"),
           let fragFn = library.makeFunction(name: "histogram_line_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtxFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            // Enable alpha blending for filled transparent histogram areas
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].alphaBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            histogramLinePipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }
        if let vtx = library.makeFunction(name: "histogram_placeholder_vertex"),
           let frag = library.makeFunction(name: "histogram_placeholder_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtx
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            placeholderPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    private func rebuildBuffers(device: MTLDevice) {
        let n = binCount.rawValue
        let accumulationLength = 4 * n * MemoryLayout<UInt32>.stride
        accumulationBuffer = device.makeBuffer(length: accumulationLength, options: .storageModeShared)
        let vertexLength = 4 * n * MemoryLayout<Float>.stride * 2 // float2 per vertex
        vertexBuffer = device.makeBuffer(length: vertexLength, options: .storageModeShared)
        needsRebuildBuffers = false
    }

    private static let histogramShaderSource = """
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

    // Filled histogram: for each bin, emit 2 vertices (bottom + top) forming a triangle strip.
    // vertex_id layout: even = bottom vertex at y=-1, odd = top vertex at curve height.
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
        // Filled area: use lower alpha; top edge is full alpha
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

    vertex float4 histogram_placeholder_vertex(uint vid [[vertex_id]]) {
        float2 uv = float2((vid << 1) & 2, vid & 2);
        return float4(uv * 2.0 - 1.0, 0, 1);
    }
    fragment float4 histogram_placeholder_fragment(float4 in [[stage_in]]) {
        return float4(0.06, 0.06, 0.08, 1);
    }
    """

}

extension HistogramScopeMTKView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable else { return }
        // When pipeline is set, use its pre-computed histogram output texture (SC-009).
        if let scopePipeline = scopePipeline {
            scopePipeline.presentHistogramToDrawable(drawable)
            return
        }
        // Fallback: compute histogram from scope.currentTexture directly (standalone mode)
        guard let rpd = currentRenderPassDescriptor,
              let cmdBuf = MetalEngine.shared?.commandQueue.makeCommandBuffer(),
              let dev = device else {
            return
        }
        if needsRebuildBuffers {
            rebuildBuffers(device: dev)
        }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clearColor

        let texture = scope?.currentTexture
        let n = binCount.rawValue
        guard let tex = texture,
              let clearPipeline = histogramClearPipelineState,
              let computePipeline = histogramComputePipelineState,
              let normalizePipeline = histogramNormalizePipelineState,
              let linePipeline = histogramLinePipelineState,
              let accum = accumulationBuffer,
              let vertBuf = vertexBuffer else {
            drawPlaceholder(cmdBuf: cmdBuf, rpd: rpd, drawable: drawable)
            return
        }

        var numBinsU32 = UInt32(n)
        var useLogU32: UInt32 = scale == .log ? 1 : 0

        guard let clearEnc = cmdBuf.makeComputeCommandEncoder() else {
            drawPlaceholder(cmdBuf: cmdBuf, rpd: rpd, drawable: drawable)
            return
        }
        clearEnc.setComputePipelineState(clearPipeline)
        clearEnc.setBuffer(accum, offset: 0, index: 0)
        clearEnc.setBytes(&numBinsU32, length: MemoryLayout<UInt32>.stride, index: 1)
        let (clearGrid, clearGroup) = ComputeDispatch.threadgroupsForBuffer1D(count: totalBins, pipeline: clearPipeline)
        clearEnc.dispatchThreadgroups(clearGrid, threadsPerThreadgroup: clearGroup)
        clearEnc.endEncoding()

        guard let compEnc = cmdBuf.makeComputeCommandEncoder() else {
            drawPlaceholder(cmdBuf: cmdBuf, rpd: rpd, drawable: drawable)
            return
        }
        compEnc.setComputePipelineState(computePipeline)
        compEnc.setTexture(tex, index: 0)
        let stride = n * MemoryLayout<UInt32>.stride
        compEnc.setBuffer(accum, offset: 0, index: 0)
        compEnc.setBuffer(accum, offset: stride, index: 1)
        compEnc.setBuffer(accum, offset: stride * 2, index: 2)
        compEnc.setBuffer(accum, offset: stride * 3, index: 3)
        compEnc.setBytes(&numBinsU32, length: MemoryLayout<UInt32>.stride, index: 4)
        let (compGrid, compGroup) = ComputeDispatch.threadgroupsForTexture2D(width: tex.width, height: tex.height, pipeline: computePipeline)
        compEnc.dispatchThreadgroups(compGrid, threadsPerThreadgroup: compGroup)
        compEnc.endEncoding()

        guard let normEnc = cmdBuf.makeComputeCommandEncoder() else {
            drawPlaceholder(cmdBuf: cmdBuf, rpd: rpd, drawable: drawable)
            return
        }
        normEnc.setComputePipelineState(normalizePipeline)
        normEnc.setBuffer(accum, offset: 0, index: 0)
        normEnc.setBuffer(vertBuf, offset: 0, index: 1)
        normEnc.setBytes(&numBinsU32, length: MemoryLayout<UInt32>.stride, index: 2)
        normEnc.setBytes(&useLogU32, length: MemoryLayout<UInt32>.stride, index: 3)
        normEnc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        normEnc.endEncoding()

        guard let lineEnc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            drawPlaceholder(cmdBuf: cmdBuf, rpd: rpd, drawable: drawable)
            return
        }
        lineEnc.setRenderPipelineState(linePipeline)
        lineEnc.setVertexBuffer(vertBuf, offset: 0, index: 0)
        let drawOrder: [Int] = [3, 0, 1, 2]
        for ch in drawOrder {
            var channel = UInt32(ch)
            lineEnc.setVertexBytes(&channel, length: MemoryLayout<UInt32>.stride, index: 1)
            lineEnc.setVertexBytes(&numBinsU32, length: MemoryLayout<UInt32>.stride, index: 2)
            lineEnc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: n * 2)
        }
        lineEnc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    private func drawPlaceholder(cmdBuf: MTLCommandBuffer, rpd: MTLRenderPassDescriptor, drawable: CAMetalDrawable) {
        guard let pipeline = placeholderPipelineState,
              let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            cmdBuf.commit()
            return
        }
        enc.setRenderPipelineState(pipeline)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI view for the histogram scope (R/G/B/Luma, 256 or 1024 bins, linear/log). SC-018: Mouse wheel zooms into detail.
public struct HistogramScopeView: View {
    private let scope: HistogramScope?
    private let pipeline: MasterPipeline?
    private let binCount: HistogramBinCount
    private let scale: HistogramScale
    @State private var scopeZoom: CGFloat = 1.0
    @State private var scopeOffset: CGSize = .zero

    public init(scope: HistogramScope? = nil, pipeline: MasterPipeline? = nil, binCount: HistogramBinCount = .bins256, scale: HistogramScale = .log) {
        self.scope = scope
        self.pipeline = pipeline
        self.binCount = binCount
        self.scale = scale
    }

    public var body: some View {
        ZStack {
            // PERF-002: CAMetalLayer-based scope display.
            ScopeDisplayRepresentable(pipeline: pipeline, scopeType: .histogram)
            GraticuleOverlay(style: .histogram)
            Text("Histogram")
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .aspectRatio(2.0, contentMode: .fit)
        .scaleEffect(scopeZoom)
        .offset(scopeOffset)
        .scopeZoomOverlay(zoom: $scopeZoom, offset: $scopeOffset)
        .clipped()
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
    }
}
