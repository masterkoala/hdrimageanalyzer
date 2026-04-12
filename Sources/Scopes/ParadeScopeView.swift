import SwiftUI
import AppKit
import Metal
import MetalKit
import Logging
import MetalEngine

// MARK: - SC-006: RGB Parade — R, G, B waveforms side-by-side (three columns)

/// Metal view: renders pipeline RGB Parade output (R/G/B accumulation resolved to one texture).
public final class ParadeScopeMTKView: MTKView {
    /// When set, draw() renders pipeline parade via renderParadeToDrawable.
    public var scopePipeline: MasterPipeline? {
        didSet { if scopePipeline != nil { isPaused = false } }
    }

    private var placeholderPipelineState: MTLRenderPipelineState?
    private let logCategory = "Scopes.Parade"

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
        guard device != nil else { return }
        clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false  // Must be false: scopePipeline uses blitEncoder.copy() to drawable
        preferredFramesPerSecond = 30
        enableSetNeedsDisplay = false
        isPaused = false
        delegate = self
        setupPlaceholderPipeline()
    }

    private func setupPlaceholderPipeline() {
        guard let device = device,
              let library = try? device.makeLibrary(source: Self.placeholderShaderSource, options: nil) else {
            return
        }
        if let fn = library.makeFunction(name: "parade_placeholder_vertex"),
           let fragFn = library.makeFunction(name: "parade_placeholder_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = fn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            placeholderPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    private static let placeholderShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };
    vertex VertexOut parade_placeholder_vertex(uint vid [[vertex_id]]) {
        float2 uv = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(uv * 2.0 - 1.0, 0, 1);
        out.uv = uv;
        return out;
    }
    fragment float4 parade_placeholder_fragment(VertexOut in [[stage_in]]) {
        float t = in.uv.y;
        float3 dark = float3(0.08, 0.04, 0.04);
        float3 top = float3(0.14, 0.08, 0.08);
        float3 c = mix(dark, top, t);
        return float4(c, 1.0);
    }
    """
}

extension ParadeScopeMTKView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable else { return }
        if let scopePipeline = scopePipeline {
            scopePipeline.presentParadeToDrawable(drawable)
            return
        }
        guard let rpd = currentRenderPassDescriptor,
              let cmdBuf = MetalEngine.shared?.commandQueue.makeCommandBuffer(),
              let pipeline = placeholderPipelineState,
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            return
        }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clearColor
        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI view for the RGB Parade scope (SC-006): pipeline output or placeholder. SC-018: Mouse wheel zooms into detail.
public struct ParadeScopeView: View {
    private let pipeline: MasterPipeline?
    @State private var scopeZoom: CGFloat = 1.0
    @State private var scopeOffset: CGSize = .zero

    public init(pipeline: MasterPipeline? = nil) {
        self.pipeline = pipeline
    }

    public var body: some View {
        ZStack {
            // PERF-002: CAMetalLayer-based scope display.
            ScopeDisplayRepresentable(pipeline: pipeline, scopeType: .parade)
            Text("RGB Parade")
                .font(.title2)
                .foregroundColor(.white.opacity(0.9))
        }
        .aspectRatio(3.0, contentMode: .fit)
        .scaleEffect(scopeZoom)
        .offset(scopeOffset)
        .scopeZoomOverlay(zoom: $scopeZoom, offset: $scopeOffset)
        .clipped()
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
    }
}
