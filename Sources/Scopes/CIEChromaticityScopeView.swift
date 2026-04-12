import SwiftUI
import AppKit
import Metal
import MetalKit
import Logging
import MetalEngine

// MARK: - SC-010/SC-013: CIE xy chromaticity diagram — 2D xy, optional spectral locus, gamut triangles, measured pixel chromaticity distribution

/// CIE 1931 xy gamut primaries (R, G, B) for Rec.709, P3-D65, Rec.2020. Used to draw gamut triangles.
public enum CIEChromaticityGamuts {
    /// Rec.709 (BT.709) — x,y for R, G, B.
    public static let rec709: [(x: Double, y: Double)] = [
        (0.64, 0.33), (0.30, 0.60), (0.15, 0.06)
    ]
    /// Display P3 (D65) — x,y for R, G, B.
    public static let p3: [(x: Double, y: Double)] = [
        (0.680, 0.320), (0.265, 0.690), (0.150, 0.060)
    ]
    /// Rec.2020 (BT.2020) — x,y for R, G, B.
    public static let rec2020: [(x: Double, y: Double)] = [
        (0.708, 0.292), (0.170, 0.797), (0.131, 0.046)
    ]
}

/// CIE 1931 2° standard observer spectral locus. Official xy chromaticity coordinates 380→780 nm (5 nm steps).
/// Source: CIE 1931 2° standard observer (chromaticity coordinates); cf. CIE 018:2019 / ISO 11664-1.
public enum CIESpectralLocus {
    /// Spectral locus: (x, y) in wavelength order from 380 nm to 780 nm (5 nm step). CIE 1931 data.
    public static let xyPoints: [(x: Double, y: Double)] = [
        (0.174112, 0.004964), (0.174008, 0.004981), (0.173801, 0.004915), (0.173560, 0.004923), (0.173337, 0.004797),
        (0.173021, 0.004775), (0.172577, 0.004799), (0.172087, 0.004833), (0.171407, 0.005102), (0.170301, 0.005789),
        (0.168878, 0.006900), (0.166895, 0.008556), (0.164412, 0.010858), (0.161105, 0.013793), (0.156641, 0.017705),
        (0.150985, 0.022740), (0.143960, 0.029703), (0.135503, 0.039879), (0.124118, 0.057803), (0.109594, 0.086843),
        (0.091294, 0.132702), (0.068706, 0.200723), (0.045391, 0.294976), (0.023460, 0.412703), (0.008168, 0.538423),
        (0.003859, 0.654823), (0.013870, 0.750186), (0.038852, 0.812016), (0.074302, 0.833803), (0.114161, 0.826207),
        (0.154722, 0.805864), (0.192876, 0.781629), (0.229620, 0.754329), (0.265775, 0.724324), (0.301604, 0.692308),
        (0.337363, 0.658848), (0.373102, 0.624451), (0.408736, 0.589607), (0.444062, 0.554714), (0.478775, 0.520202),
        (0.512486, 0.486591), (0.544787, 0.454434), (0.575151, 0.424232), (0.602933, 0.396497), (0.627037, 0.372491),
        (0.648233, 0.351395), (0.665764, 0.334011), (0.680079, 0.319747), (0.691504, 0.308342), (0.700606, 0.299301),
        (0.707918, 0.292027), (0.714032, 0.285929), (0.719033, 0.280935), (0.723032, 0.276948), (0.725992, 0.274008),
        (0.728272, 0.271728), (0.729969, 0.270031), (0.731089, 0.268911), (0.731993, 0.268007), (0.732719, 0.267281),
        (0.733417, 0.266583), (0.734047, 0.265953), (0.734390, 0.265610), (0.734592, 0.265408), (0.734690, 0.265310),
        (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310),
        (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310),
        (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310),
        (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310),
        (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310),
        (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310),
        (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310), (0.734690, 0.265310),
        (0.734690, 0.265310)
    ]
}

/// Diagram xy range used by kernel and overlay (must match Metal kernel kCIE_xyMax).
private let kCIE_xyMax: Double = 0.85

/// Maps CIE xy to view coordinates: x → [0,w], y → [0,h] with y=0 at bottom.
private func xyToView(x: Double, y: Double, width w: CGFloat, height h: CGFloat) -> CGPoint {
    let xNorm = x / kCIE_xyMax
    let yNorm = y / kCIE_xyMax
    return CGPoint(
        x: CGFloat(xNorm) * w,
        y: (1 - CGFloat(yNorm)) * h
    )
}

// MARK: - Spectral locus overlay (optional)

private struct SpectralLocusOverlay: View {
    var showSpectralLocus: Bool
    var body: some View {
        if !showSpectralLocus { return AnyView(EmptyView()) }
        return AnyView(
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let pts = CIESpectralLocus.xyPoints
                Path { p in
                    guard let first = pts.first else { return }
                    let pt = xyToView(x: first.x, y: first.y, width: w, height: h)
                    p.move(to: pt)
                    for i in 1..<pts.count {
                        let pt = xyToView(x: pts[i].x, y: pts[i].y, width: w, height: h)
                        p.addLine(to: pt)
                    }
                }
                .stroke(Color.white.opacity(0.5), lineWidth: 1.0)
            }
            .allowsHitTesting(false)
        )
    }
}

// MARK: - SC-012: Gamut triangles overlay (Rec.709, DCI-P3, Rec.2020)

private struct GamutTrianglesOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                gamutTriangle(CIEChromaticityGamuts.rec709, color: .red, lineWidth: 1.2, w: w, h: h)
                gamutTriangle(CIEChromaticityGamuts.p3, color: .green, lineWidth: 1.0, w: w, h: h)
                gamutTriangle(CIEChromaticityGamuts.rec2020, color: .blue, lineWidth: 0.8, w: w, h: h)
            }
        }
        .allowsHitTesting(false)
    }

    private func gamutTriangle(_ primaries: [(x: Double, y: Double)], color: Color, lineWidth: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        guard primaries.count >= 3 else { return AnyView(EmptyView()) }
        let p0 = xyToView(x: primaries[0].x, y: primaries[0].y, width: w, height: h)
        let p1 = xyToView(x: primaries[1].x, y: primaries[1].y, width: w, height: h)
        let p2 = xyToView(x: primaries[2].x, y: primaries[2].y, width: w, height: h)
        return AnyView(
            Path { path in
                path.move(to: p0)
                path.addLine(to: p1)
                path.addLine(to: p2)
                path.closeSubpath()
            }
            .stroke(color.opacity(0.85), lineWidth: lineWidth)
        )
    }
}

// MARK: - Metal view: CIE xy accumulation from pipeline

public final class CIEChromaticityScopeMTKView: MTKView {
    public var scopePipeline: MasterPipeline? {
        didSet { if scopePipeline != nil { isPaused = false } }
    }

    private var gradientPipelineState: MTLRenderPipelineState?
    private let logCategory = "Scopes.CIEChromaticity"

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
        clearColor = MTLClearColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
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
        if let fn = library.makeFunction(name: "cie_placeholder_vertex"),
           let fragFn = library.makeFunction(name: "cie_placeholder_fragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = fn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            gradientPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }
    }

    private static let placeholderShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut { float4 position [[position]]; float2 uv; };
    vertex VertexOut cie_placeholder_vertex(uint vid [[vertex_id]]) {
        float2 uv = float2((vid << 1) & 2, vid & 2);
        VertexOut out;
        out.position = float4(uv * 2.0 - 1.0, 0, 1);
        out.uv = uv;
        return out;
    }
    fragment float4 cie_placeholder_fragment(VertexOut in [[stage_in]]) {
        float3 dark = float3(0.06, 0.06, 0.08);
        float3 top = float3(0.10, 0.10, 0.12);
        return float4(mix(dark, top, in.uv.y), 1.0);
    }
    """
}

extension CIEChromaticityScopeMTKView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable else { return }
        if let scopePipeline = scopePipeline {
            scopePipeline.presentCieChromaticityToDrawable(drawable)
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

// MARK: - SwiftUI wrapper

/// SC-010/SC-013: CIE xy chromaticity diagram — pipeline plots measured pixel chromaticity distribution (2D histogram in xy); overlay draws spectral locus (optional) and gamut triangles (709, P3, 2020). SC-018: Mouse wheel zooms into detail.
public struct CIEChromaticityScopeView: View {
    private let pipeline: MasterPipeline?
    /// When true, draw the CIE 1931 spectral locus curve. Default true.
    public var showSpectralLocus: Bool
    @State private var scopeZoom: CGFloat = 1.0
    @State private var scopeOffset: CGSize = .zero

    public init(pipeline: MasterPipeline? = nil, showSpectralLocus: Bool = true) {
        self.pipeline = pipeline
        self.showSpectralLocus = showSpectralLocus
    }

    public var body: some View {
        ZStack {
            // PERF-002: CAMetalLayer-based scope display.
            ScopeDisplayRepresentable(pipeline: pipeline, scopeType: .ciexy)
            VStack(spacing: 2) {
                Text("CIE xy")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.9))
                Text("Pixel chromaticity distribution")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
            GraticuleOverlay(style: .cieChromaticity, verticalDivisions: 6, horizontalDivisions: 6)
            SpectralLocusOverlay(showSpectralLocus: showSpectralLocus)
            GamutTrianglesOverlay()
        }
        .scaleEffect(scopeZoom)
        .offset(scopeOffset)
        .scopeZoomOverlay(zoom: $scopeZoom, offset: $scopeOffset)
        .clipped()
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
    }
}
