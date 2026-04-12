import SwiftUI
import MetalEngine
import Common
import Scopes

/// LUT Preview panel — shows the current display with a split-view wipe indicator
/// showing where the LUT is applied. Uses a draggable slider to control the split.
struct LUTPreviewPanelView: View {
    @EnvironmentObject var sharedState: SharedAppState
    @State private var splitPosition: CGFloat = 0.5
    @State private var showLabels: Bool = true

    private var captureState: CapturePreviewState { sharedState.captureState }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if captureState.pipelineForDisplay != nil {
                    ScopeDisplayRepresentable(
                        pipeline: captureState.pipelineForDisplay,
                        scopeType: .waveform
                    )
                    .overlay(splitOverlay)
                } else {
                    noSignalPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            controlsBar
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            Text("LUT: \(captureState.lutLoadState.displayName)")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)

            Spacer()

            HStack(spacing: 4) {
                Text("Split")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                Slider(value: $splitPosition, in: 0...1)
                    .frame(maxWidth: 100)
            }

            Toggle("Labels", isOn: $showLabels)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 10))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.4))
    }

    private var splitOverlay: some View {
        GeometryReader { geo in
            let xPos = geo.size.width * splitPosition
            // Split line
            Rectangle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 2)
                .position(x: xPos, y: geo.size.height / 2)
            // Labels
            if showLabels {
                Text("Original")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(4)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(4)
                    .position(x: max(40, xPos / 2), y: 16)
                Text("LUT Applied")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(4)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(4)
                    .position(x: min(geo.size.width - 50, xPos + (geo.size.width - xPos) / 2), y: 16)
            }
        }
    }

    private var noSignalPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "cube.transparent")
                .font(.title)
                .foregroundColor(.gray)
            Text("No LUT Loaded")
                .font(.caption)
                .foregroundColor(.gray)
            Text("Load a .cube or .3dmesh file")
                .font(.caption2)
                .foregroundColor(.gray.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
    }
}
