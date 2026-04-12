import SwiftUI
import AppKit
import Metal
import MetalKit
import Logging
import MetalEngine

// MARK: - SC-007: Vectorscope — U/V scatter, center=neutral, radius=saturation, skin tone line

/// Metal view: renders pipeline vectorscope output (Cb/Cr accumulation) and optional skin tone line overlay.
public final class VectorscopeScopeMTKView: MTKView {
    /// When set, draw() renders pipeline vectorscope via renderVectorscopeToDrawable.
    public var scopePipeline: MasterPipeline? {
        didSet { if scopePipeline != nil { isPaused = false } }
    }

    private var gradientPipelineState: MTLRenderPipelineState?
    private let logCategory = "Scopes.Vectorscope"

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
        setupGradientPipeline()
    }

    private func setupGradientPipeline() {
        guard let device = device,
              let library = try? device.makeLibrary(source: Self.gradientShaderSource, options: nil) else {
            return
        }
        if let fn = library.makeFunction(name: "vectorscope_placeholder_vertex"),
           let fragFn = library.makeFunction(name: "vectorscope_placeholder_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = fn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            gradientPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    private static let gradientShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };
    vertex VertexOut vectorscope_placeholder_vertex(uint vid [[vertex_id]]) {
        float2 uv = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(uv * 2.0 - 1.0, 0, 1);
        out.uv = uv;
        return out;
    }
    fragment float4 vectorscope_placeholder_fragment(VertexOut in [[stage_in]]) {
        float t = in.uv.y;
        float3 dark = float3(0.06, 0.06, 0.08);
        float3 top = float3(0.12, 0.12, 0.16);
        float3 c = mix(dark, top, t);
        return float4(c, 1.0);
    }
    """
}

extension VectorscopeScopeMTKView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable else { return }
        if let scopePipeline = scopePipeline {
            scopePipeline.presentVectorscopeToDrawable(drawable)
            return
        }
        guard let rpd = currentRenderPassDescriptor,
              let cmdBuf = MetalEngine.shared?.commandQueue.makeCommandBuffer(),
              let pipeline = gradientPipelineState,
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

// MARK: - SC-008: Vectorscope graticule — saturation rings, crosshairs, color targets, I/Q lines

/// Professional vectorscope graticule: concentric rings at 25/50/75/100%, crosshairs, I/Q axes, and color target boxes.
private struct VectorscopeGraticuleOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w * 0.5
            let cy = h * 0.5
            let scale = min(w, h)

            ZStack {
                // Saturation rings at 25%, 50%, 75%, 100%
                Path { p in
                    for pct in [0.25, 0.50, 0.75, 1.0] {
                        let r = pct * 0.5 * scale
                        p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                    }
                }
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)

                // Center crosshairs
                Path { p in
                    p.move(to: CGPoint(x: cx, y: cy - 0.5 * scale))
                    p.addLine(to: CGPoint(x: cx, y: cy + 0.5 * scale))
                    p.move(to: CGPoint(x: cx - 0.5 * scale, y: cy))
                    p.addLine(to: CGPoint(x: cx + 0.5 * scale, y: cy))
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 0.5)

                // I/Q axis lines (33° and 123° from positive Cb axis)
                let iqLength = 0.5 * scale
                Path { p in
                    // I-axis at 33°
                    let iAngle = 33.0 * .pi / 180.0
                    p.move(to: CGPoint(x: cx - cos(iAngle) * iqLength, y: cy + sin(iAngle) * iqLength))
                    p.addLine(to: CGPoint(x: cx + cos(iAngle) * iqLength, y: cy - sin(iAngle) * iqLength))
                    // Q-axis at 123° (perpendicular to I)
                    let qAngle = 123.0 * .pi / 180.0
                    p.move(to: CGPoint(x: cx - cos(qAngle) * iqLength, y: cy + sin(qAngle) * iqLength))
                    p.addLine(to: CGPoint(x: cx + cos(qAngle) * iqLength, y: cy - sin(qAngle) * iqLength))
                }
                .stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))

                // 75% color target boxes (standard broadcast vectors for R, Mg, B, Cy, G, Yl)
                // BT.709 75% color bar Cb/Cr positions (normalized 0-1, where 0.5=center)
                let targets: [(name: String, cb: Double, cr: Double, color: Color)] = [
                    ("R",  0.5 - 0.169, 0.5 + 0.500, .red),
                    ("Mg", 0.5 + 0.331, 0.5 + 0.419, Color(red: 1.0, green: 0.0, blue: 1.0)),
                    ("B",  0.5 + 0.500, 0.5 - 0.081, .blue),
                    ("Cy", 0.5 + 0.169, 0.5 - 0.500, .cyan),
                    ("G",  0.5 - 0.331, 0.5 - 0.419, .green),
                    ("Yl", 0.5 - 0.500, 0.5 + 0.081, .yellow),
                ]
                ForEach(0..<targets.count, id: \.self) { i in
                    let t = targets[i]
                    let tx = cx + (t.cb - 0.5) * scale
                    let ty = cy - (t.cr - 0.5) * scale
                    let boxSize: CGFloat = 10
                    Rectangle()
                        .stroke(t.color.opacity(0.6), lineWidth: 1)
                        .frame(width: boxSize, height: boxSize)
                        .position(x: tx, y: ty)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Skin tone line overlay at 123° (industry standard I-line)

/// Overlay that draws the skin tone reference line at 123° through the vectorscope center.
/// The skin tone line (I-line) at 123° is the standard reference angle where all human skin tones cluster.
private struct SkinToneLineOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w * 0.5
            let cy = h * 0.5
            let scale = min(w, h)
            // Skin tone line at 123° from positive Cb axis (industry standard)
            let angle = 123.0 * .pi / 180.0
            let innerR = 0.05 * scale
            let outerR = 0.5 * scale
            let x1 = cx + cos(angle) * innerR
            let y1 = cy - sin(angle) * innerR
            let x2 = cx + cos(angle) * outerR
            let y2 = cy - sin(angle) * outerR
            Path { p in
                p.move(to: CGPoint(x: x1, y: y1))
                p.addLine(to: CGPoint(x: x2, y: y2))
            }
            .stroke(Color.orange.opacity(0.8), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI view for the vectorscope (SC-007): pipeline output + skin tone line overlay. SC-018: Mouse wheel zooms into detail (20x max), drag to pan, double-click reset.
public struct VectorscopeScopeView: View {
    private let pipeline: MasterPipeline?
    @State private var scopeZoom: CGFloat = 1.0
    @State private var scopeOffset: CGSize = .zero

    public init(pipeline: MasterPipeline? = nil) {
        self.pipeline = pipeline
    }

    public var body: some View {
        ZStack {
            // PERF-002: CAMetalLayer-based scope display.
            ScopeDisplayRepresentable(pipeline: pipeline, scopeType: .vectorscope)
            VectorscopeGraticuleOverlay()
            SkinToneLineOverlay()
            Text("Vectorscope")
                .font(.caption)
                .foregroundColor(.white.opacity(0.4))
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .scaleEffect(scopeZoom)
        .offset(scopeOffset)
        .scopeZoomOverlay(zoom: $scopeZoom, offset: $scopeOffset, maxZoom: 20.0, centerLocked: true)
        .clipped()
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
    }
}
