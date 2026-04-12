import SwiftUI
import AppKit
import Metal
import MetalKit
import MetalEngine

// MARK: - AU-010: Phase meter Lissajous display using Metal

/// Metal view: draws L/R phase correlation as a Lissajous (XY) pattern. X = left, Y = right in [-1, 1].
/// Feed (left, right) sample arrays from PhaseCorrelationMeter.lissajousSamples for live display.
public final class LissajousScopeMTKView: MTKView {
    /// Sample data for Lissajous: (left channel, right channel). Set from UI thread; draw() reads and renders.
    public var lissajousSamples: (left: [Float], right: [Float])? {
        didSet { setNeedsDisplay(bounds) }
    }

    private var linePipelineState: MTLRenderPipelineState?
    private var placeholderPipelineState: MTLRenderPipelineState?
    /// Vertex buffer: float2 per point, capacity maxLissajousPoints.
    private var vertexBuffer: MTLBuffer?
    private static let maxLissajousPoints = 4096

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
        clearColor = MTLClearColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        delegate = self
        vertexBuffer = dev.makeBuffer(length: Self.maxLissajousPoints * MemoryLayout<Float>.stride * 2, options: .storageModeShared)
        setupPipelines(device: dev)
    }

    private func setupPipelines(device: MTLDevice) {
        guard let library = try? device.makeLibrary(source: Self.lissajousShaderSource, options: nil) else { return }
        if let vtx = library.makeFunction(name: "lissajous_line_vertex"),
           let frag = library.makeFunction(name: "lissajous_line_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtx
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            linePipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }
        if let vtx = library.makeFunction(name: "lissajous_placeholder_vertex"),
           let frag = library.makeFunction(name: "lissajous_placeholder_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtx
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            placeholderPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    private static let lissajousShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct LissajousVertexOut {
        float4 position [[position]];
    };

    vertex LissajousVertexOut lissajous_line_vertex(
        uint vid [[vertex_id]],
        device const float2* points [[buffer(0)]],
        constant uint* pointCount [[buffer(1)]])
    {
        uint n = pointCount[0];
        LissajousVertexOut o;
        if (vid >= n) {
            o.position = float4(0, 0, 0, 1);
            return o;
        }
        float2 p = points[vid];
        o.position = float4(p.x, p.y, 0, 1);
        return o;
    }

    fragment float4 lissajous_line_fragment(LissajousVertexOut in [[stage_in]]) {
        return float4(0.2, 0.85, 0.75, 0.95);
    }

    vertex float4 lissajous_placeholder_vertex(uint vid [[vertex_id]]) {
        float2 uv = float2((vid << 1) & 2, vid & 2);
        return float4(uv * 2.0 - 1.0, 0, 1);
    }

    fragment float4 lissajous_placeholder_fragment(float4 in [[stage_in]]) {
        float3 dark = float3(0.06, 0.06, 0.08);
        float3 top = float3(0.10, 0.10, 0.12);
        float t = (in.y + 1.0) * 0.5;
        return float4(mix(dark, top, t), 1.0);
    }
    """
}

extension LissajousScopeMTKView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let cmdBuf = MetalEngine.shared?.commandQueue.makeCommandBuffer() else {
            return
        }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clearColor

        let samples = lissajousSamples
        let count: Int
        if let s = samples, !s.left.isEmpty, s.left.count == s.right.count {
            count = min(s.left.count, Self.maxLissajousPoints)
            if let buf = vertexBuffer, count > 0 {
                buf.contents().withMemoryRebound(to: Float.self, capacity: Self.maxLissajousPoints * 2) { ptr in
                    for i in 0..<count {
                        ptr[i * 2 + 0] = s.left[i]
                        ptr[i * 2 + 1] = s.right[i]
                    }
                }
                if let linePipeline = linePipelineState,
                   let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) {
                    var n = UInt32(count)
                    enc.setRenderPipelineState(linePipeline)
                    enc.setVertexBuffer(buf, offset: 0, index: 0)
                    enc.setVertexBytes(&n, length: MemoryLayout<UInt32>.stride, index: 1)
                    enc.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: count)
                    enc.endEncoding()
                    cmdBuf.present(drawable)
                    cmdBuf.commit()
                    return
                }
            }
        }

        guard let placeholder = placeholderPipelineState,
              let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            cmdBuf.commit()
            return
        }
        enc.setRenderPipelineState(placeholder)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI view for the phase meter Lissajous (XY) scope. Pass (left, right) from PhaseCorrelationMeter.lissajousSamples.
public struct LissajousScopeView: View {
    /// Optional L/R sample arrays for Lissajous. When nil or empty, a placeholder is drawn.
    let leftSamples: [Float]?
    let rightSamples: [Float]?

    public init(leftSamples: [Float]? = nil, rightSamples: [Float]? = nil) {
        self.leftSamples = leftSamples
        self.rightSamples = rightSamples
    }

    public var body: some View {
        LissajousScopeRepresentable(left: leftSamples, right: rightSamples)
    }
}

private struct LissajousScopeRepresentable: NSViewRepresentable {
    let left: [Float]?
    let right: [Float]?

    func makeNSView(context: Context) -> LissajousScopeMTKView {
        let view = LissajousScopeMTKView(frame: .zero, device: MetalEngine.shared?.device)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: LissajousScopeMTKView, context: Context) {
        guard let l = left, let r = right, l.count == r.count, !l.isEmpty else {
            nsView.lissajousSamples = nil
            return
        }
        nsView.lissajousSamples = (left: l, right: r)
    }
}
