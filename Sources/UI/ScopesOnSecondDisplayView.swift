import SwiftUI
import AppKit
import Logging
import Common
import Capture
import Scopes
import MetalEngine

// MARK: - Move window to second display (UI-013)

/// NSViewRepresentable that moves the hosting window to the second display when attached (UI-013). Runs once per window.
private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window, context.coordinator.didRun == false else { return }
        context.coordinator.didRun = true
        DispatchQueue.main.async {
            moveWindowToSecondDisplay(window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var didRun = false
    }
}

/// If multiple displays exist, positions the window on the second display (screens[1]). Otherwise leaves the window where it is.
private func moveWindowToSecondDisplay(_ window: NSWindow) {
    let screens = NSScreen.screens
    guard screens.count >= 2 else {
        HDRLogger.info(category: "UI", "Single display: scopes window not moved")
        return
    }
    let targetScreen = screens[1]
    let frame = targetScreen.visibleFrame
    window.setFrame(frame, display: true, animate: true)
    HDRLogger.info(category: "UI", "Scopes window moved to second display")
}

// MARK: - Scopes window content (UI-013)

/// Full-window 2×2 scope quadrant grid for the "Scopes on Second Display" window. Shares state with main window via SharedAppState.
public struct ScopesOnSecondDisplayView: View {
    @EnvironmentObject private var sharedState: SharedAppState

    private var captureState: CapturePreviewState { sharedState.captureState }
    private var waveformScope: WaveformScope { sharedState.waveformScope }
    private var histogramScope: HistogramScope { sharedState.histogramScope }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Compact toolbar for second display
            HStack(spacing: 8) {
                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AJATheme.accent)
                Text("Scopes — Display 2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AJATheme.secondaryText)
                Spacer()
                LayoutToolbarView(layoutManager: sharedState.layoutManager)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(AJATheme.panelBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AJATheme.border.opacity(0.6))
                    .frame(height: 1)
            }
            // Flexible scope grid (synced with main window layout)
            FlexibleLayoutView(
                layoutManager: sharedState.layoutManager,
                panelBuilder: { index, contentBinding in
                    AnyView(
                        ScopePanelContentOnlyView(
                            content: contentBinding,
                            quadrantIndex: index,
                            captureState: captureState,
                            pipeline: captureState.pipelineForDisplay,
                            waveformScope: waveformScope,
                            histogramScope: histogramScope,
                            waveformMode: $sharedState.waveformMode,
                            waveformLuminanceScale: sharedState.waveformLuminanceScale,
                            waveformLogScale: $sharedState.waveformLogScale,
                            waveformSingleLineMode: sharedState.waveformSingleLineMode
                        )
                    )
                }
            )
            .padding(AJATheme.panelSpacing)
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(AJATheme.windowBackground)
        .background(WindowAccessor())
        .onAppear {
            captureState.scope = waveformScope
            captureState.histogramScope = histogramScope
            // SC-020: Sync per-scope intensity and histogram mode to pipeline
            if let p = captureState.pipelineForDisplay {
                p.waveformGamma = sharedState.waveformGamma
                p.waveformGain = sharedState.waveformGain
                p.vectorscopeGamma = sharedState.vectorscopeGamma
                p.vectorscopeGain = sharedState.vectorscopeGain
                p.paradeGamma = sharedState.paradeGamma
                p.paradeGain = sharedState.paradeGain
                p.ciexyGamma = sharedState.ciexyGamma
                p.ciexyGain = sharedState.ciexyGain
                p.histogramDisplayMode = sharedState.histogramDisplayMode
            }
        }
        .onChange(of: sharedState.waveformGamma) { _, new in captureState.pipelineForDisplay?.waveformGamma = new }
        .onChange(of: sharedState.waveformGain) { _, new in captureState.pipelineForDisplay?.waveformGain = new }
        .onChange(of: sharedState.vectorscopeGamma) { _, new in captureState.pipelineForDisplay?.vectorscopeGamma = new }
        .onChange(of: sharedState.vectorscopeGain) { _, new in captureState.pipelineForDisplay?.vectorscopeGain = new }
        .onChange(of: sharedState.paradeGamma) { _, new in captureState.pipelineForDisplay?.paradeGamma = new }
        .onChange(of: sharedState.paradeGain) { _, new in captureState.pipelineForDisplay?.paradeGain = new }
        .onChange(of: sharedState.ciexyGamma) { _, new in captureState.pipelineForDisplay?.ciexyGamma = new }
        .onChange(of: sharedState.ciexyGain) { _, new in captureState.pipelineForDisplay?.ciexyGain = new }
        .onChange(of: sharedState.histogramDisplayMode) { _, new in
            captureState.pipelineForDisplay?.histogramDisplayMode = new
        }
    }
}
