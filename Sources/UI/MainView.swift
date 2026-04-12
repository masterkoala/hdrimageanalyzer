import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import Logging
import Common
import Capture
import Scopes
import Audio
import MetalEngine

/// Identifiable item for full-screen scope panel (UI-004).
private struct FullScreenScopeItem: Identifiable {
    let quadrantIndex: Int
    var id: Int { quadrantIndex }
}

/// Main UI with 2×2 quadrant layout (Phase 7 UI-001, UI-002, UI-003, UI-004). Each quadrant shows video or any scope; picker per quadrant. Drag a quadrant onto another to swap content. Full-screen button per quadrant shows single scope in full-screen. UI-013: uses SharedAppState so scopes window on display 2 stays in sync.
public struct MainView: View {
    @EnvironmentObject private var sharedState: SharedAppState
    @Environment(\.openWindow) private var openWindow
    @StateObject private var audioMeterState = AudioMeterState()
    @State private var fullScreenScope: FullScreenScopeItem?
    @State private var showPresetsSheet: Bool = false
    @State private var showLayoutSheet: Bool = false
    @State private var showPreferencesSheet: Bool = false
    @State private var preferencesSheetTab: String? = nil
    @State private var isCapturing: Bool = false
    @State private var isWindowFullScreen: Bool = false
    @AppStorage(AudioChannelMappingPrefsKeys.channelMappingPreset) private var channelMappingPresetRaw: String = AudioChannelMappingPreset.numeric.rawValue
    @AppStorage(AudioChannelMappingPrefsKeys.channelMappingCustomLabels) private var channelMappingCustomLabelsJSON: String = ""

    private var audioChannelLabels: [String] {
        let preset = AudioChannelMappingPreset(rawValue: channelMappingPresetRaw) ?? .numeric
        let custom: [String] = (try? JSONDecoder().decode([String].self, from: Data((channelMappingCustomLabelsJSON.isEmpty ? "[]" : channelMappingCustomLabelsJSON).utf8))) ?? []
        return AudioChannelMappingConfig.labels(for: preset, customLabels: custom)
    }

    private var captureState: CapturePreviewState { sharedState.captureState }
    private var waveformScope: WaveformScope { sharedState.waveformScope }
    private var histogramScope: HistogramScope { sharedState.histogramScope }

    public init() {}

    // MARK: - Body (split to help Swift type-checker)

    /// Merged publisher for all menu notifications — avoids 16+ chained .onReceive modifiers
    /// that crash the Swift type-checker (signal 11).
    private var menuNotificationPublisher: AnyPublisher<Notification, Never> {
        Publishers.MergeMany([
            NotificationCenter.default.publisher(for: AppMenuNotifications.takeScreenshot),
            NotificationCenter.default.publisher(for: AppMenuNotifications.takeScopeScreenshot),
            NotificationCenter.default.publisher(for: AppMenuNotifications.copyScreenshotToPasteboard),
            NotificationCenter.default.publisher(for: AppMenuNotifications.startTimedScreenshot),
            NotificationCenter.default.publisher(for: AppMenuNotifications.stopTimedScreenshot),
            NotificationCenter.default.publisher(for: AppMenuNotifications.export),
            NotificationCenter.default.publisher(for: AppMenuNotifications.openPresets),
            NotificationCenter.default.publisher(for: AppMenuNotifications.showScopesOnSecondDisplay),
            NotificationCenter.default.publisher(for: AppMenuNotifications.openHelp),
            NotificationCenter.default.publisher(for: AppMenuNotifications.viewLayout),
            NotificationCenter.default.publisher(for: AppMenuNotifications.viewZoomIn),
            NotificationCenter.default.publisher(for: AppMenuNotifications.viewZoomOut),
            NotificationCenter.default.publisher(for: AppMenuNotifications.viewActualSize),
            NotificationCenter.default.publisher(for: AppMenuNotifications.openDevicePicker),
            NotificationCenter.default.publisher(for: AppMenuNotifications.openFormatPicker),
            NotificationCenter.default.publisher(for: AppMenuNotifications.openScopeType),
            NotificationCenter.default.publisher(for: AppMenuNotifications.openDisplayOptions),
            NotificationCenter.default.publisher(for: AppMenuNotifications.openColorspace),
        ]).eraseToAnyPublisher()
    }

    private func handleMenuNotification(_ notification: Notification) {
        switch notification.name {
        case AppMenuNotifications.takeScreenshot:
            saveDisplayScreenshot()
        case AppMenuNotifications.takeScopeScreenshot:
            saveScopeScreenshot()
        case AppMenuNotifications.copyScreenshotToPasteboard:
            copyDisplayScreenshotToPasteboard()
        case AppMenuNotifications.startTimedScreenshot:
            startTimedScreenshotCapture()
        case AppMenuNotifications.stopTimedScreenshot:
            captureState.stopTimedScreenshotCapture()
        case AppMenuNotifications.export:
            saveDisplayScreenshot()
        case AppMenuNotifications.openPresets:
            showPresetsSheet = true
        case AppMenuNotifications.showScopesOnSecondDisplay:
            openWindow(id: "scopes")
        case AppMenuNotifications.openHelp:
            openWindow(id: "help")
        case AppMenuNotifications.viewLayout:
            showLayoutSheet = true
        case AppMenuNotifications.viewZoomIn:
            sharedState.viewZoomIn()
        case AppMenuNotifications.viewZoomOut:
            sharedState.viewZoomOut()
        case AppMenuNotifications.viewActualSize:
            sharedState.viewActualSize()
        case AppMenuNotifications.openDevicePicker:
            sharedState.quadrant1Content = .video
        case AppMenuNotifications.openFormatPicker:
            sharedState.quadrant1Content = .video
        case AppMenuNotifications.openScopeType:
            sharedState.quadrant1Content = .waveform
        case AppMenuNotifications.openDisplayOptions:
            preferencesSheetTab = "Display"
            showPreferencesSheet = true
        case AppMenuNotifications.openColorspace:
            preferencesSheetTab = "General"
            showPreferencesSheet = true
        default:
            break
        }
    }

    public var body: some View {
        mainContentWithSheets
            .onReceive(menuNotificationPublisher) { notification in
                handleMenuNotification(notification)
            }
    }

    /// Sheets layer — extracted from body to reduce type-checker load.
    private var mainContentWithSheets: some View {
        mainContentWithChangeHandlers
            .sheet(isPresented: $showPresetsSheet) {
                PresetsSheetView(
                    onLoad: applyPresetConfig,
                    onSaveAs: savePresetAs,
                    onDismiss: { showPresetsSheet = false }
                )
            }
            .sheet(item: $fullScreenScope) { item in
                fullScreenScopeView(quadrantIndex: item.quadrantIndex)
            }
            .sheet(isPresented: $showPreferencesSheet) {
                preferencesSheetContent
            }
            .sheet(isPresented: $showLayoutSheet) {
                LayoutPresetsSheet(
                    onApplyDefault: { applyLayoutDefault(); showLayoutSheet = false },
                    onApplyAllVideo: { applyLayoutAllVideo(); showLayoutSheet = false },
                    onApplyScopesOnly: { applyLayoutScopesOnly(); showLayoutSheet = false },
                    onSaveAsDefault: { saveLayoutToConfig(); showLayoutSheet = false },
                    onDismiss: { showLayoutSheet = false }
                )
            }
    }

    /// Preferences sheet content — extracted to reduce nesting depth.
    private var preferencesSheetContent: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { showPreferencesSheet = false }
                    .keyboardShortcut(.defaultAction)
                    .padding(12)
            }
            PreferencesView(initialTabIdentifier: preferencesSheetTab)
                .frame(minWidth: 440, minHeight: 360)
        }
        .onDisappear { preferencesSheetTab = nil }
    }

    /// Main content with onAppear + onChange handlers, extracted to help Swift type-checker.
    private var mainContentWithChangeHandlers: some View {
        mainContentLayout
            .onAppear(perform: handleMainViewAppear)
            .onChange(of: captureState.selectedDeviceIndex) { _, _ in
                captureState.refreshInputSourceCache()
            }
            .onChange(of: captureState.selectedModeIndex) { _, _ in
                captureState.refreshInputSourceCache()
            }
            .onReceive(sharedState.objectWillChange) { _ in
                syncScopeParameters()
            }
    }

    /// Sync all scope parameters from SharedAppState to the pipeline in a single pass.
    private func syncScopeParameters() {
        guard let pipeline = captureState.pipelineForDisplay else { return }
        pipeline.waveformGamma = sharedState.waveformGamma
        pipeline.waveformGain = sharedState.waveformGain
        pipeline.vectorscopeGamma = sharedState.vectorscopeGamma
        pipeline.vectorscopeGain = sharedState.vectorscopeGain
        pipeline.paradeGamma = sharedState.paradeGamma
        pipeline.paradeGain = sharedState.paradeGain
        pipeline.ciexyGamma = sharedState.ciexyGamma
        pipeline.ciexyGain = sharedState.ciexyGain
        pipeline.histogramDisplayMode = sharedState.histogramDisplayMode
        pipeline.enabledScopes = sharedState.visibleScopeTypes
    }

    /// Core layout without change handlers — split to reduce type-checker load.
    private var mainContentLayout: some View {
        VStack(spacing: 0) {
            ScopeToolbarView(
                layoutManager: sharedState.layoutManager,
                isCapturing: $isCapturing,
                isFullScreen: $isWindowFullScreen,
                onToggleCapture: { toggleCapture() },
                onScreenshot: { saveDisplayScreenshot() },
                onOpenSettings: { showPreferencesSheet = true },
                onToggleFullScreen: { toggleWindowFullScreen() }
            )
            quadrantGrid
            Divider()
                .background(AJATheme.divider)
            ScrollView {
                scopePanel
            }
            .frame(maxHeight: 400, alignment: .top)
            .layoutPriority(-1)
            .background(AJATheme.elevatedBackground)
            Divider()
                .background(AJATheme.divider)
            enhancedStatusBarSection
        }
        .frame(minWidth: 720, minHeight: 420)
        .background(AJATheme.windowBackground)
    }

    private func handleMainViewAppear() {
        _ = MetalEngine.shared
        captureState.scope = waveformScope
        captureState.histogramScope = histogramScope
        // NET-006: Register scope JPEG stream provider for Web UI
        WebRemoteBridge.registerScopeStreamProvider { [sharedState] in
            guard let img = sharedState.captureState.pipelineForDisplay?.captureScopeScreenshot() else { return nil }
            return TextureCapture.encodeToJPEGData(img)
        }
        // NET-007: Input source (device + format) for Web UI
        WebRemoteBridge.registerInputSourceProvider { [weak sharedState] in
            sharedState?.captureState.getInputSourceCachedData()
        }
        WebRemoteBridge.registerInputSourceSelectionCallback { [weak sharedState] deviceIndex, modeIndex in
            DispatchQueue.main.async {
                guard let state = sharedState?.captureState else { return }
                state.selectedDeviceIndex = max(0, deviceIndex)
                state.refreshModes()
                state.selectedModeIndex = max(0, min(modeIndex, state.modes.count - 1))
            }
        }
        // NET-007: Colorspace for Web UI
        WebRemoteBridge.registerColorspaceProvider {
            AppConfig.current.defaultColorSpace.rawValue
        }
        WebRemoteBridge.registerColorspaceSelectionCallback { raw in
            DispatchQueue.main.async {
                var config = AppConfig.current
                if let cs = Common.ColorSpace(rawValue: raw) {
                    config.defaultColorSpace = cs
                    AppConfig.save(config)
                }
            }
        }
        // SC-020: Sync per-scope intensity and histogram mode from shared state to pipeline
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
            // PERF-001: Only compute visible scopes.
            p.enabledScopes = sharedState.visibleScopeTypes
        }
        // NET-007: Populate input source cache for Web UI (avoids main.sync deadlock when capture is running).
        captureState.refreshInputSourceCache()
    }

    /// Content binding for a quadrant (1–4). Used by full-screen view.
    private func contentBinding(for quadrantIndex: Int) -> Binding<QuadrantContent> {
        switch quadrantIndex {
        case 1: return $sharedState.quadrant1Content
        case 2: return $sharedState.quadrant2Content
        case 3: return $sharedState.quadrant3Content
        case 4: return $sharedState.quadrant4Content
        default: return $sharedState.quadrant1Content
        }
    }

    /// Full-screen overlay showing a single scope panel or video (UI-004). In Four Channel mode shows video for that channel (UI-016).
    private func fullScreenScopeView(quadrantIndex: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if sharedState.isFourChannelMode {
                    VideoPreviewOnlyView(state: captureState, isPrimaryDriver: true)
                } else {
                    ScopePanelContentOnlyView(
                        content: contentBinding(for: quadrantIndex),
                        quadrantIndex: quadrantIndex,
                        captureState: captureState,
                        pipeline: captureState.pipelineForDisplay,
                        waveformScope: waveformScope,
                        histogramScope: histogramScope,
                        waveformMode: $sharedState.waveformMode,
                        waveformLuminanceScale: sharedState.waveformLuminanceScale,
                        waveformLogScale: $sharedState.waveformLogScale,
                        waveformSingleLineMode: sharedState.waveformSingleLineMode
                    )
                }
            }
            .background(Color.black)
            Button("Exit Full Screen") {
                fullScreenScope = nil
            }
            .buttonStyle(.borderedProminent)
            .tint(AJATheme.accent)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func saveDisplayScreenshot() {
        guard let pipeline = captureState.pipelineForDisplay,
              let image = pipeline.captureDisplayScreenshot(),
              let engine = MetalEngine.shared else { return }
        presentSavePanel(for: image, engine: engine, name: "Display")
    }

    private func saveScopeScreenshot() {
        guard let pipeline = captureState.pipelineForDisplay,
              let image = pipeline.captureScopeScreenshot(),
              let engine = MetalEngine.shared else { return }
        presentSavePanel(for: image, engine: engine, name: "Scope")
    }

    /// QC-009: Start timed screenshot capture with default 5s interval and Documents/HDRAnalyzerScreenshots. Menu can post startTimedScreenshot.
    private func startTimedScreenshotCapture() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HDRAnalyzerScreenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        captureState.startTimedScreenshotCapture(mode: .timeBased(intervalSeconds: 5), outputDirectory: dir, filenamePrefix: "screenshot")
    }

    private func presentSavePanel(for image: CGImage, engine: MetalEngine, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "HDRAnalyzer_\(name)_\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).png"
        panel.begin { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            let format: ScreenshotFormat = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" ? .jpeg : .png
            _ = engine.saveScreenshot(image, to: url, format: format)
        }
    }

    private func copyDisplayScreenshotToPasteboard() {
        guard let pipeline = captureState.pipelineForDisplay,
              let image = pipeline.captureDisplayScreenshot(),
              let engine = MetalEngine.shared else { return }
        engine.copyScreenshotToPasteboard(image)
    }

    // MARK: - UI-011 Layout preset save/recall

    private func applyPresetConfig(_ config: AppConfig) {
        AppConfig.save(config)
        sharedState.quadrant1Content = QuadrantContent(rawValue: config.layoutQuadrant1 ?? QuadrantContent.video.rawValue) ?? .video
        sharedState.quadrant2Content = QuadrantContent(rawValue: config.layoutQuadrant2 ?? QuadrantContent.waveform.rawValue) ?? .waveform
        sharedState.quadrant3Content = QuadrantContent(rawValue: config.layoutQuadrant3 ?? QuadrantContent.histogram.rawValue) ?? .histogram
        sharedState.quadrant4Content = QuadrantContent(rawValue: config.layoutQuadrant4 ?? QuadrantContent.vectorscope.rawValue) ?? .vectorscope
    }

    private func savePresetAs(_ name: String) {
        var config = AppConfig.current
        config.layoutQuadrant1 = sharedState.quadrant1Content.rawValue
        config.layoutQuadrant2 = sharedState.quadrant2Content.rawValue
        config.layoutQuadrant3 = sharedState.quadrant3Content.rawValue
        config.layoutQuadrant4 = sharedState.quadrant4Content.rawValue
        PresetManager.save(Preset(name: name, config: config))
    }

    /// Apply default layout: Quad mode with Video, Waveform, Histogram, Vectorscope (UI-011).
    private func applyLayoutDefault() {
        sharedState.layoutManager.applyLayout(.quad)
        // Keep legacy properties in sync
        sharedState.quadrant1Content = .video
        sharedState.quadrant2Content = .waveform
        sharedState.quadrant3Content = .histogram
        sharedState.quadrant4Content = .vectorscope
    }

    /// Apply all panels to Video (UI-011).
    private func applyLayoutAllVideo() {
        let lm = sharedState.layoutManager
        for i in 0..<lm.panels.count {
            lm.panels[i].content = .video
        }
        lm.saveToDefaults()
        // Keep legacy properties in sync
        sharedState.quadrant1Content = .video
        sharedState.quadrant2Content = .video
        sharedState.quadrant3Content = .video
        sharedState.quadrant4Content = .video
    }

    /// Apply scopes-only layout: Quad mode with Waveform, Histogram, Vectorscope, RGB Parade (UI-011).
    private func applyLayoutScopesOnly() {
        sharedState.layoutManager.applyLayout(.quad)
        let contents: [QuadrantContent] = [.waveform, .histogram, .vectorscope, .parade]
        let lm = sharedState.layoutManager
        for (i, c) in contents.enumerated() where i < lm.panels.count {
            lm.panels[i].content = c
        }
        lm.saveToDefaults()
        // Keep legacy properties in sync
        sharedState.quadrant1Content = .waveform
        sharedState.quadrant2Content = .histogram
        sharedState.quadrant3Content = .vectorscope
        sharedState.quadrant4Content = .parade
    }

    /// Save current quadrant layout to AppConfig as default (UI-011).
    private func saveLayoutToConfig() {
        var config = AppConfig.current
        config.layoutQuadrant1 = sharedState.quadrant1Content.rawValue
        config.layoutQuadrant2 = sharedState.quadrant2Content.rawValue
        config.layoutQuadrant3 = sharedState.quadrant3Content.rawValue
        config.layoutQuadrant4 = sharedState.quadrant4Content.rawValue
        AppConfig.save(config)
    }

    /// Swaps content between two quadrants (1–4). Used by drag-to-swap (UI-003).
    private func swapQuadrantContent(source: Int, target: Int) {
        guard source != target, (1...4).contains(source), (1...4).contains(target) else { return }
        let contents = [sharedState.quadrant1Content, sharedState.quadrant2Content, sharedState.quadrant3Content, sharedState.quadrant4Content]
        var swapped = contents
        swapped.swapAt(source - 1, target - 1)
        sharedState.quadrant1Content = swapped[0]
        sharedState.quadrant2Content = swapped[1]
        sharedState.quadrant3Content = swapped[2]
        sharedState.quadrant4Content = swapped[3]
    }

    /// Layout grid: Four Channel mode (UI-016) shows 4× video preview; otherwise flexible layout (UI-020).
    @ViewBuilder
    private var quadrantGrid: some View {
        Group {
            if sharedState.isFourChannelMode {
                fourChannelGrid
            } else {
                flexibleScopeGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// UI-016: 4× video preview in quadrants (Ch 1–4). Single pipeline for all; only Ch 1 drives processFrame() to avoid main-thread freeze.
    private var fourChannelGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                QuadrantContainerView(title: "Ch 1", onEnterFullScreen: { fullScreenScope = FullScreenScopeItem(quadrantIndex: 1) }) {
                    VideoPreviewOnlyView(state: captureState, isPrimaryDriver: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                QuadrantContainerView(title: "Ch 2", onEnterFullScreen: { fullScreenScope = FullScreenScopeItem(quadrantIndex: 2) }) {
                    VideoPreviewOnlyView(state: captureState, isPrimaryDriver: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                QuadrantContainerView(title: "Ch 3", onEnterFullScreen: { fullScreenScope = FullScreenScopeItem(quadrantIndex: 3) }) {
                    VideoPreviewOnlyView(state: captureState, isPrimaryDriver: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                QuadrantContainerView(title: "Ch 4", onEnterFullScreen: { fullScreenScope = FullScreenScopeItem(quadrantIndex: 4) }) {
                    VideoPreviewOnlyView(state: captureState, isPrimaryDriver: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Flexible scope grid: uses FlexibleLayoutView with the layout manager (UI-020).
    /// Supports 9 layout modes (single, side-by-side, stacked, quad, triple, 3x1, 1x3, six-pack)
    /// with drag-to-swap, context menus, and animated transitions.
    private var flexibleScopeGrid: some View {
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
            },
            onEnterFullScreen: { index in
                fullScreenScope = FullScreenScopeItem(quadrantIndex: index)
            }
        )
        .padding(AJATheme.panelSpacing)
    }

    private var scopePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            MetadataDisplayPanelView(
                level1: captureState.metadata.currentDolbyVisionL1,
                level2: captureState.metadata.currentDolbyVisionL2,
                hdr10Static: captureState.metadata.currentHDR10Static,
                l1History: captureState.metadata.l1History
            )
            .frame(minWidth: 320)
            Divider()
            // QC-010: QC dashboard panel (violation counts, alerts)
            QCDashboardPanelView()
            Divider()
            LUTBrowserView(lutState: captureState.lutLoadState)
                .onChange(of: captureState.lutLoadState.displayName) { _, _ in
                    captureState.syncLUTToPipeline()
                }
            Divider()
            AudioMeterView(
                peakLevels: audioMeterState.peakLevels,
                rmsLevels: audioMeterState.rmsLevels,
                showRMS: audioMeterState.showRMS,
                channelLabels: Array(audioChannelLabels.prefix(max(2, audioMeterState.peakLevels.count)))
            )
            .frame(minHeight: 100)
            AudioMeter16ChannelLayoutView(
                peakLevels: audioMeterState.peakLevels,
                rmsLevels: audioMeterState.rmsLevels,
                showRMS: audioMeterState.showRMS,
                channelLabels: audioChannelLabels
            )
            .frame(minHeight: 120)
            Text("Phase (Lissajous)")
                .font(.headline)
                .foregroundStyle(AJATheme.secondaryText)
            LissajousScopeView(
                leftSamples: audioMeterState.lissajousLeft,
                rightSamples: audioMeterState.lissajousRight
            )
            .frame(minWidth: 200, minHeight: 200)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Divider()
            Text("Scope: Waveform")
                .font(.headline)
                .foregroundStyle(AJATheme.secondaryText)
            Picker("Mode", selection: $sharedState.waveformMode) {
                ForEach(WaveformMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 12) {
                Picker("Scale", selection: $sharedState.waveformLuminanceScale) {
                    Text("SDR IRE").tag(GraticuleLuminanceScale.sdrIRE)
                    Text("HDR 10k nits").tag(GraticuleLuminanceScale.hdrPQNits)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Log Y", isOn: $sharedState.waveformLogScale)
                    .toggleStyle(.switch)
                Toggle("Single line", isOn: $sharedState.waveformSingleLineMode)
                    .toggleStyle(.switch)
            }
            // SC-020: Per-scope gain/gamma for waveform
            scopeSettingsRow(label: "Waveform", gain: $sharedState.waveformGain, gamma: $sharedState.waveformGamma)
            // PERF-003: Scope views removed from bottom panel — they are already displayed
            // in the quadrant grid above. Keeping only the settings controls here.
            Divider()
            Text("Scope: Histogram")
                .font(.headline)
                .foregroundStyle(AJATheme.secondaryText)
            Picker("Mode", selection: $sharedState.histogramDisplayMode) {
                ForEach(HistogramDisplayMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            Text("Scope: Vectorscope")
                .font(.headline)
                .foregroundStyle(AJATheme.secondaryText)
            scopeSettingsRow(label: "Vectorscope", gain: $sharedState.vectorscopeGain, gamma: $sharedState.vectorscopeGamma)
            Divider()
            Text("Scope: RGB Parade")
                .font(.headline)
                .foregroundStyle(AJATheme.secondaryText)
            scopeSettingsRow(label: "Parade", gain: $sharedState.paradeGain, gamma: $sharedState.paradeGamma)
            Divider()
            Text("Scope: CIE xy")
                .font(.headline)
                .foregroundStyle(AJATheme.secondaryText)
            scopeSettingsRow(label: "CIE", gain: $sharedState.ciexyGain, gamma: $sharedState.ciexyGamma)
        }
        .padding()
    }

    /// SC-020: Compact per-scope gain/gamma row.
    @ViewBuilder
    private func scopeSettingsRow(label: String, gain: Binding<Float>, gamma: Binding<Float>) -> some View {
        HStack(spacing: 10) {
            Text("Gain")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: gain, in: 0.5...2.5, step: 0.05)
                .frame(maxWidth: 120)
            Text(String(format: "%.2f", gain.wrappedValue))
                .font(.caption2.monospacedDigit())
                .frame(width: 30, alignment: .leading)
            Text("Gamma")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: gamma, in: 0.3...1.0, step: 0.05)
                .frame(maxWidth: 120)
            Text(String(format: "%.2f", gamma.wrappedValue))
                .font(.caption2.monospacedDigit())
                .frame(width: 30, alignment: .leading)
        }
    }

    // MARK: - Enhanced status bar (UI-020)

    /// Professional status bar with signal LED, format info, and performance indicators.
    @ViewBuilder
    private var enhancedStatusBarSection: some View {
        EnhancedStatusBarView(
            signalStatus: currentSignalStatus,
            formatString: statusFormatString,
            frameRateString: statusFrameRateString,
            timecodeString: captureState.metadata.currentTimecode ?? "00:00:00:00",
            colorSpaceString: AppConfig.current.defaultColorSpace.rawValue,
            cpuUsage: 0,
            gpuUsage: 0,
            memoryUsageMB: 0,
            scopeFPS: 0
        )
    }

    /// Derive signal status from capture state.
    private var currentSignalStatus: SignalStatus {
        if captureState.selectedDeviceInfo == nil {
            return .disconnected
        }
        if isCapturing {
            if captureState.metadata.currentFormatWidth != nil {
                return .live
            }
            return .unstable
        }
        return .noSignal
    }

    private var statusFormatString: String {
        if let w = captureState.metadata.currentFormatWidth,
           let h = captureState.metadata.currentFormatHeight {
            return "\(w)x\(h)"
        }
        if let mode = captureState.selectedMode {
            return "\(mode.width)x\(mode.height)"
        }
        return "--"
    }

    private var statusFrameRateString: String {
        if let fps = captureState.metadata.currentFrameRate {
            if fps == fps.rounded() {
                return "\(Int(fps))"
            }
            return String(format: "%.2f", fps)
        }
        if let mode = captureState.selectedMode {
            let fps = mode.frameRate
            if fps == fps.rounded() {
                return "\(Int(fps))"
            }
            return String(format: "%.2f", fps)
        }
        return "--"
    }

    // MARK: - Toolbar actions

    private func toggleCapture() {
        isCapturing.toggle()
        if isCapturing {
            captureState.startCapture()
        } else {
            captureState.stopCapture()
        }
    }

    private func toggleWindowFullScreen() {
        if let window = NSApplication.shared.mainWindow {
            window.toggleFullScreen(nil)
            isWindowFullScreen.toggle()
        }
    }
}

// MARK: - Layout presets sheet (View > Layout)

private struct LayoutPresetsSheet: View {
    var onApplyDefault: () -> Void
    var onApplyAllVideo: () -> Void
    var onApplyScopesOnly: () -> Void
    var onSaveAsDefault: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Quadrant Layout")
                .font(.title2)
                .foregroundStyle(AJATheme.primaryText)
            Text("Choose a preset or save the current layout as default.")
                .font(.subheadline)
                .foregroundStyle(AJATheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                Button("Default (Video, Waveform, Histogram, Vectorscope)") { onApplyDefault() }
                    .buttonStyle(.borderedProminent)
                Button("All Video") { onApplyAllVideo() }
                    .buttonStyle(.bordered)
                Button("Scopes Only (Waveform, Histogram, Vectorscope, Parade)") { onApplyScopesOnly() }
                    .buttonStyle(.bordered)
                Button("Save current as default") { onSaveAsDefault() }
                    .buttonStyle(.bordered)
            }
            .padding()
            Spacer(minLength: 8)
            Button("Cancel") { onDismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(minWidth: 360, minHeight: 280)
        .padding(24)
        .background(AJATheme.windowBackground)
    }
}

