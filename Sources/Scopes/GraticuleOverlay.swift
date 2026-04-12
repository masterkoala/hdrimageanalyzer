import SwiftUI

// MARK: - SC-016 Graticule: grid lines, axis labels, scale markers over scope views
// MARK: - SC-017 IRE scale (SDR), nits scale (HDR PQ)

/// Vertical (luminance) axis scale for waveform graticule. Used to switch between SDR IRE and HDR PQ nits.
public enum GraticuleLuminanceScale {
    /// SDR: Y axis 0–100 IRE.
    case sdrIRE
    /// HDR PQ: Y axis 0–10000 nits.
    case hdrPQNits
}

/// Style preset for graticule (waveform, histogram, vectorscope). Drives grid divisions and label formatting.
public enum GraticuleStyle {
    /// Waveform: X = 0–100% horizontal, Y = IRE (SDR) or nits (HDR PQ) per luminanceScale.
    case waveform
    /// Histogram: X = 0–255 or bin index, Y = relative count (0–1).
    case histogram
    /// Vectorscope: rectangular grid; center = neutral; X = Cb/U, Y = Cr/V (0–1).
    case vectorscope
    /// SC-010: CIE xy chromaticity; X = x, Y = y (0–0.85).
    case cieChromaticity
}

/// Reusable overlay that draws grid lines, axis labels, and scale markers over scope views.
/// Use as a SwiftUI overlay on top of MTKView (e.g. `ZStack { scopeView; GraticuleOverlay(style: .waveform) }`).
public struct GraticuleOverlay: View {
    /// Style determines divisions and label format.
    public var style: GraticuleStyle
    /// For waveform: SDR IRE (0–100) or HDR PQ nits (0–10000). Ignored for other styles.
    public var luminanceScale: GraticuleLuminanceScale
    /// Number of vertical grid lines (including edges). Default 5 → 4 divisions.
    public var verticalDivisions: Int
    /// Number of horizontal grid lines (including edges). Default 5 → 4 divisions.
    public var horizontalDivisions: Int
    /// Whether to draw axis labels (scale markers). Default true.
    public var showLabels: Bool
    /// Grid and label color. Default white with opacity.
    public var lineColor: Color
    public var labelColor: Color
    /// Line width for grid. Default 0.5.
    public var lineWidth: CGFloat

    public init(
        style: GraticuleStyle,
        luminanceScale: GraticuleLuminanceScale = .sdrIRE,
        verticalDivisions: Int = 5,
        horizontalDivisions: Int = 5,
        showLabels: Bool = true,
        lineColor: Color = Color.white.opacity(0.35),
        labelColor: Color = Color.white.opacity(0.75),
        lineWidth: CGFloat = 0.5
    ) {
        self.style = style
        self.luminanceScale = luminanceScale
        self.verticalDivisions = max(2, verticalDivisions)
        self.horizontalDivisions = max(2, horizontalDivisions)
        self.showLabels = showLabels
        self.lineColor = lineColor
        self.labelColor = labelColor
        self.lineWidth = lineWidth
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                // Grid lines
                gridPath(width: w, height: h)
                    .stroke(lineColor, lineWidth: lineWidth)
                if showLabels {
                    labelsView(width: w, height: h)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private func gridPath(width w: CGFloat, height h: CGFloat) -> Path {
        var path = Path()
        let vDiv = CGFloat(verticalDivisions - 1)
        let hDiv = CGFloat(horizontalDivisions - 1)
        guard vDiv > 0, hDiv > 0 else { return path }
        for i in 0..<verticalDivisions {
            let x = (CGFloat(i) / vDiv) * w
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: h))
        }
        for i in 0..<horizontalDivisions {
            let y = (CGFloat(i) / hDiv) * h
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: w, y: y))
        }
        return path
    }

    private func labelsView(width w: CGFloat, height h: CGFloat) -> some View {
        let vDiv = verticalDivisions - 1
        let hDiv = horizontalDivisions - 1
        let font = Font.system(size: 9, weight: .medium, design: .monospaced)
        return ZStack(alignment: .topLeading) {
            // Bottom axis (X)
            ForEach(0..<verticalDivisions, id: \.self) { i in
                let t = vDiv > 0 ? Double(i) / Double(vDiv) : 0
                let x = w * CGFloat(t)
                Text(xLabel(t))
                    .font(font)
                    .foregroundColor(labelColor)
                    .position(x: x, y: h - 6)
            }
            // Left axis (Y)
            ForEach(0..<horizontalDivisions, id: \.self) { i in
                let t = hDiv > 0 ? Double(i) / Double(hDiv) : 0
                let y = h * (1 - CGFloat(t))
                Text(yLabel(t))
                    .font(font)
                    .foregroundColor(labelColor)
                    .position(x: 14, y: y)
            }
        }
    }

    private func xLabel(_ t: Double) -> String {
        switch style {
        case .waveform:
            return "\(Int(t * 100))%"
        case .histogram:
            return "\(Int(t * 255))"
        case .vectorscope:
            return String(format: "%.2f", t)
        case .cieChromaticity:
            return String(format: "%.2f", t * 0.85)
        }
    }

    private func yLabel(_ t: Double) -> String {
        switch style {
        case .waveform:
            switch luminanceScale {
            case .sdrIRE:
                return "\(Int(t * 100))"  // 0–100 IRE
            case .hdrPQNits:
                return "\(Int(t * 10000))"  // 0–10000 nits
            }
        case .histogram:
            return String(format: "%.0f%%", t * 100)
        case .vectorscope:
            return String(format: "%.2f", t)
        case .cieChromaticity:
            return String(format: "%.2f", (1.0 - t) * 0.85)
        }
    }
}

// MARK: - Preview (when run in app)

#if DEBUG
struct GraticuleOverlay_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            GraticuleOverlay(style: .waveform, luminanceScale: .sdrIRE)
                .frame(width: 300, height: 200)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            GraticuleOverlay(style: .waveform, luminanceScale: .hdrPQNits)
                .frame(width: 300, height: 200)
                .background(Color(red: 0.08, green: 0.08, blue: 0.1))
        }
    }
}
#endif
