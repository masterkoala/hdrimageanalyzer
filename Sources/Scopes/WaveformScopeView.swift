import SwiftUI
import AppKit
import Metal
import MetalKit
import Logging
import Common
import MetalEngine

// MARK: - Scope model (interface for future update from MasterPipeline)

/// Waveform scope: receives texture updates via update(texture:) for future rendering.
public final class WaveformScope: ScopeTextureUpdatable {
    /// Latest texture from pipeline (for future draw; placeholder view does not render it yet).
    public private(set) var currentTexture: MTLTexture?

    public init() {}

    public func update(texture: MTLTexture?) {
        currentTexture = texture
    }
}

// MARK: - MTKView (luminance waveform or placeholder)

/// Metal view: dark background; draws real luminance waveform from scope.currentTexture or pipeline scope output (MT-009) or placeholder.
public final class WaveformScopeMTKView: MTKView {
    /// When set, draw() samples texture per column and draws min/max luminance as vertical lines.
    public weak var scope: WaveformScope?
    /// When set, draw() renders pipeline scope output via renderScopeToDrawable; takes precedence over scope waveform.
    public var scopePipeline: MasterPipeline? {
        didSet { if scopePipeline != nil { isPaused = false } }
    }

    private var gradientPipelineState: MTLRenderPipelineState?
    private var waveformComputePipelineState: MTLComputePipelineState?
    private var waveformLinePipelineState: MTLRenderPipelineState?
    private var columnMinMaxBuffer: MTLBuffer?
    private static let kMaxWaveformColumns = 2048
    private let logCategory = "Scopes.Waveform"

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
        setupGradientPipeline()
        setupWaveformPipelines(device: dev)
        columnMinMaxBuffer = dev.makeBuffer(length: Self.kMaxWaveformColumns * 2 * MemoryLayout<Float>.stride, options: .storageModeShared)
    }

    private func setupGradientPipeline() {
        guard let device = device,
              let library = try? device.makeLibrary(source: Self.gradientShaderSource, options: nil) else {
            return
        }
        if let fn = library.makeFunction(name: "waveform_placeholder_vertex"),
           let fragFn = library.makeFunction(name: "waveform_placeholder_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = fn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            gradientPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    private func setupWaveformPipelines(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: Self.waveformShaderSource, options: nil) else { return }
        if let computeFn = library.makeFunction(name: "waveform_luminance_columns") {
            waveformComputePipelineState = try? device.makeComputePipelineState(function: computeFn)
        }
        if let vtxFn = library.makeFunction(name: "waveform_line_vertex"),
           let fragFn = library.makeFunction(name: "waveform_line_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtxFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            waveformLinePipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    private static let gradientShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };
    vertex VertexOut waveform_placeholder_vertex(uint vid [[vertex_id]]) {
        float2 uv = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(uv * 2.0 - 1.0, 0, 1);
        out.uv = uv;
        return out;
    }
    fragment float4 waveform_placeholder_fragment(VertexOut in [[stage_in]]) {
        float t = in.uv.y;
        float3 dark = float3(0.06, 0.06, 0.08);
        float3 top = float3(0.12, 0.12, 0.16);
        float3 c = mix(dark, top, t);
        return float4(c, 1.0);
    }
    """

    private static let waveformShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    constant float kLumR = 0.2126;
    constant float kLumG = 0.7152;
    constant float kLumB = 0.0722;
    kernel void waveform_luminance_columns(
        texture2d<float, access::read> src [[texture(0)]],
        device float* minMax [[buffer(0)]],
        uint col [[thread_position_in_grid]])
    {
        uint w = src.get_width();
        uint h = src.get_height();
        if (col >= w || h == 0) return;
        float mn = 1.0;
        float mx = 0.0;
        for (uint row = 0; row < h; row++) {
            float4 p = src.read(uint2(col, row));
            float lum = kLumR * p.r + kLumG * p.g + kLumB * p.b;
            mn = min(mn, lum);
            mx = max(mx, lum);
        }
        minMax[col * 2 + 0] = mn;
        minMax[col * 2 + 1] = mx;
    }
    struct WaveformVertexOut { float4 position [[position]]; };
    vertex WaveformVertexOut waveform_line_vertex(
        uint vid [[vertex_id]],
        device const float* minMax [[buffer(0)]],
        constant uint* columnCount [[buffer(1)]])
    {
        uint n = columnCount[0];
        if (n == 0) n = 1;
        uint lineIndex = vid / 2u;
        uint isTop = vid % 2u;
        float denom = float(max(1u, n - 1u));
        float x = (float(lineIndex) / denom) * 2.0 - 1.0;
        float y = minMax[lineIndex * 2u + isTop];
        WaveformVertexOut o;
        o.position = float4(x, y * 2.0 - 1.0, 0, 1);
        return o;
    }
    fragment float4 waveform_line_fragment(WaveformVertexOut in [[stage_in]]) {
        return float4(0.2, 0.85, 0.5, 1.0);
    }
    """
}

extension WaveformScopeMTKView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable else { return }
        if let scopePipeline = scopePipeline {
            scopePipeline.presentScopeToDrawable(drawable)
            return
        }
        guard let rpd = currentRenderPassDescriptor,
              let cmdBuf = MetalEngine.shared?.commandQueue.makeCommandBuffer() else {
            return
        }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clearColor

        let texture = scope?.currentTexture
        if let tex = texture,
           let computePipeline = waveformComputePipelineState,
           let linePipeline = waveformLinePipelineState,
           let buf = columnMinMaxBuffer {
            let columnCount = min(tex.width, Self.kMaxWaveformColumns)
            if columnCount > 0 {
                guard let encoder = cmdBuf.makeComputeCommandEncoder() else {
                    fallbackDraw(cmdBuf: cmdBuf, rpd: rpd, drawable: drawable)
                    return
                }
                encoder.setComputePipelineState(computePipeline)
                encoder.setTexture(tex, index: 0)
                encoder.setBuffer(buf, offset: 0, index: 0)
                let (grid, group) = ComputeDispatch.threadgroupsForBuffer1D(count: columnCount, pipeline: computePipeline)
                encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
                encoder.endEncoding()

                var colCountU32 = UInt32(columnCount)
                guard let lineEncoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
                    fallbackDraw(cmdBuf: cmdBuf, rpd: rpd, drawable: drawable)
                    return
                }
                lineEncoder.setRenderPipelineState(linePipeline)
                lineEncoder.setVertexBuffer(buf, offset: 0, index: 0)
                lineEncoder.setVertexBytes(&colCountU32, length: MemoryLayout<UInt32>.stride, index: 1)
                lineEncoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: columnCount * 2)
                lineEncoder.endEncoding()
                cmdBuf.present(drawable)
                cmdBuf.commit()
                return
            }
        }

        fallbackDraw(cmdBuf: cmdBuf, rpd: rpd, drawable: drawable)
    }

    private func fallbackDraw(cmdBuf: MTLCommandBuffer, rpd: MTLRenderPassDescriptor, drawable: CAMetalDrawable) {
        guard let pipeline = gradientPipelineState,
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            cmdBuf.commit()
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI view for the waveform scope (MTKView: pipeline scope output, or luminance from scope, or placeholder).
/// SC-005: waveformMode binding drives pipeline.waveformMode (Luminance, RGB Overlay, YCbCr).
/// SC-019: graticuleLuminanceScale drives 0–100 IRE vs 0–10000 nits; waveformLogScale drives log10(1+nits) Y axis.
/// SC-018: Mouse wheel zooms into detail (scale 1×–8×).
/// SC-023: waveformSingleLineMode shows only one scan line (center row).
public struct WaveformScopeView: View {
    private let scope: WaveformScope?
    private let pipeline: MasterPipeline?
    private let waveformMode: Binding<WaveformMode>
    /// Graticule Y-axis scale: SDR IRE (0–100) or HDR PQ nits (0–10000). SC-017.
    private let graticuleLuminanceScale: GraticuleLuminanceScale
    /// SC-019: When true, luminance axis is displayed in log scale (log10(1+nits)).
    private let waveformLogScale: Bool
    /// SC-023: When true, waveform shows only one scan line (center row).
    private let waveformSingleLineMode: Bool
    @State private var scopeZoom: CGFloat = 1.0
    @State private var scopeOffset: CGSize = .zero

    /// Creates a waveform scope view. Pass pipeline for live scope output; scope for update(texture:) waveform; waveformMode for mode picker; graticuleLuminanceScale for IRE vs nits; waveformLogScale for log Y axis; waveformSingleLineMode for single scan line.
    public init(scope: WaveformScope? = nil, pipeline: MasterPipeline? = nil, waveformMode: Binding<WaveformMode> = .constant(.luminance), graticuleLuminanceScale: GraticuleLuminanceScale = .sdrIRE, waveformLogScale: Bool = false, waveformSingleLineMode: Bool = false) {
        self.scope = scope
        self.pipeline = pipeline
        self.waveformMode = waveformMode
        self.graticuleLuminanceScale = graticuleLuminanceScale
        self.waveformLogScale = waveformLogScale
        self.waveformSingleLineMode = waveformSingleLineMode
    }

    public var body: some View {
        ZStack {
            // PERF-002: CAMetalLayer-based scope display with settings sync.
            WaveformScopeDisplayRepresentable(pipeline: pipeline, waveformMode: waveformMode.wrappedValue, graticuleLuminanceScale: graticuleLuminanceScale, waveformLogScale: waveformLogScale, waveformSingleLineMode: waveformSingleLineMode)
            GraticuleOverlay(style: .waveform, luminanceScale: graticuleLuminanceScale)
            Text("Waveform")
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

/// PERF-002: CAMetalLayer-based waveform display with settings sync.
private struct WaveformScopeDisplayRepresentable: NSViewRepresentable {
    let pipeline: MasterPipeline?
    let waveformMode: WaveformMode
    let graticuleLuminanceScale: GraticuleLuminanceScale
    let waveformLogScale: Bool
    let waveformSingleLineMode: Bool

    func makeNSView(context: Context) -> ScopeDisplayLayerView {
        let view = ScopeDisplayLayerView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.pipeline = pipeline
        view.scopeType = .waveform
        syncSettings()
        return view
    }

    func updateNSView(_ nsView: ScopeDisplayLayerView, context: Context) {
        nsView.pipeline = pipeline
        nsView.scopeType = .waveform
        syncSettings()
    }

    private func syncSettings() {
        guard let p = pipeline else { return }
        p.waveformMode = waveformMode
        p.waveformMaxNits = graticuleLuminanceScale == .hdrPQNits ? 10000 : 100
        p.waveformLogScale = waveformLogScale
        p.waveformSingleLineMode = waveformSingleLineMode
    }
}
