import SwiftUI
import MetalEngine

/// 3D Color space visualization — renders a rotatable 3D RGB cube wireframe
/// with gamut boundary overlay. Drag to rotate, pinch to zoom.
struct ColorSpace3DView: View {
    let pipeline: MasterPipeline?
    @State private var rotationX: Double = -25
    @State private var rotationY: Double = 45
    @State private var zoom: Double = 1.0
    @State private var showWireframe: Bool = true
    @State private var showGamutBoundary: Bool = true
    @State private var colorModel: ColorModel = .rgb

    enum ColorModel: String, CaseIterable {
        case rgb = "RGB"
        case hsl = "HSL"
        case ycbcr = "YCbCr"
        var displayName: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(white: 0.06)
                cube3DCanvas
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        rotationY += value.translation.width * 0.5
                        rotationX += value.translation.height * 0.5
                    }
            )
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        zoom = max(0.5, min(3.0, value))
                    }
            )

            controlsBar
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            Picker("Space", selection: $colorModel) {
                ForEach(ColorModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)

            Toggle("Wireframe", isOn: $showWireframe)
                .toggleStyle(.switch)
                .controlSize(.mini)

            Toggle("Gamut", isOn: $showGamutBoundary)
                .toggleStyle(.switch)
                .controlSize(.mini)

            Spacer()

            Button("Reset") {
                rotationX = -25
                rotationY = 45
                zoom = 1.0
            }
            .controlSize(.mini)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.4))
    }

    private var cube3DCanvas: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let scale = min(size.width, size.height) * 0.35 * zoom

            if showWireframe {
                drawWireframeCube(context: context, center: center, scale: scale)
            }

            if showGamutBoundary {
                drawGamutTriangle(context: context, center: center, scale: scale)
            }
        }
    }

    private func drawWireframeCube(context: GraphicsContext, center: CGPoint, scale: Double) {
        let vertices: [(Double, Double, Double)] = [
            (0,0,0), (1,0,0), (1,1,0), (0,1,0),
            (0,0,1), (1,0,1), (1,1,1), (0,1,1)
        ]
        let edges = [(0,1),(1,2),(2,3),(3,0),(4,5),(5,6),(6,7),(7,4),(0,4),(1,5),(2,6),(3,7)]

        for (a, b) in edges {
            let p1 = project3D(vertices[a], center: center, scale: scale)
            let p2 = project3D(vertices[b], center: center, scale: scale)
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            context.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 1)
        }

        // Axis labels
        let rPos = project3D((1.12, 0, 0), center: center, scale: scale)
        let gPos = project3D((0, 1.12, 0), center: center, scale: scale)
        let bPos = project3D((0, 0, 1.12), center: center, scale: scale)
        context.draw(Text("R").font(.system(size: 11, weight: .bold)).foregroundColor(.red), at: rPos)
        context.draw(Text("G").font(.system(size: 11, weight: .bold)).foregroundColor(.green), at: gPos)
        context.draw(Text("B").font(.system(size: 11, weight: .bold)).foregroundColor(.blue), at: bPos)

        // White point
        let wPos = project3D((1, 1, 1), center: center, scale: scale)
        context.draw(Text("W").font(.system(size: 9)).foregroundColor(.white.opacity(0.6)), at: wPos)
    }

    private func drawGamutTriangle(context: GraphicsContext, center: CGPoint, scale: Double) {
        let gamutVertices: [(Double, Double, Double)] = [
            (1, 0, 0), (0, 1, 0), (0, 0, 1)
        ]
        var gamutPath = Path()
        for (i, v) in gamutVertices.enumerated() {
            let p = project3D(v, center: center, scale: scale)
            if i == 0 { gamutPath.move(to: p) } else { gamutPath.addLine(to: p) }
        }
        gamutPath.closeSubpath()
        context.fill(gamutPath, with: .color(.cyan.opacity(0.08)))
        context.stroke(gamutPath, with: .color(.cyan.opacity(0.4)), lineWidth: 1.5)
    }

    /// 3D to 2D perspective projection with rotation around X and Y axes.
    private func project3D(_ point: (Double, Double, Double), center: CGPoint, scale: Double) -> CGPoint {
        let (x, y, z) = (point.0 - 0.5, point.1 - 0.5, point.2 - 0.5)
        let radY = rotationY * .pi / 180
        let radX = rotationX * .pi / 180

        let x1 = x * cos(radY) - z * sin(radY)
        let z1 = x * sin(radY) + z * cos(radY)
        let y1 = y * cos(radX) - z1 * sin(radX)
        let z2 = y * sin(radX) + z1 * cos(radX)

        let perspective = 1.0 / (1.0 + z2 * 0.3)
        return CGPoint(
            x: center.x + x1 * scale * perspective,
            y: center.y - y1 * scale * perspective
        )
    }
}
