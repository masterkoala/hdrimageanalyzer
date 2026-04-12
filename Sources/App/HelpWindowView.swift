import SwiftUI

/// INT-010: In-app Help window. Content matches Docs/UserGuide.md (canonical source for external docs).
struct HelpWindowView: View {
    private static let helpContent = """
    # HDR Image Analyzer Pro — User Guide

    Professional HDR video analysis for Blackmagic DeckLink. This guide covers setup, input, scopes, and workflows.

    ---

    ## Getting Started

    - **Requirements:** macOS 14+, Blackmagic DeckLink hardware, Desktop Video drivers installed.
    - **Launch:** Open HDR Image Analyzer Pro. The main window shows a 2×2 quadrant layout and scope panel.
    - **Web UI:** When the app is running, open http://localhost:8765/ in a browser for remote monitoring and control.

    ---

    ## Main Window

    - **Title bar:** App name and phase info.
    - **Four Channel toggle:** When on, each quadrant shows video from channel 1–4 (multi-link capture). When off, each quadrant can show video or a scope (waveform, vectorscope, histogram, etc.).
    - **Quadrants:** Drag a quadrant's content onto another to swap. Use the full-screen button on a quadrant to show that content in full screen.
    - **Scope panel:** Scrollable strip of scope types; select which scope is shown in the main quadrant when not in Four Channel mode.
    - **Status bar:** Capture status (device, format, resolution, frame rate).

    ---

    ## Menus & Shortcuts

    - **File:** Presets, Export, Screenshot (Display / Scope), Copy Screenshot, Timed screenshot start/stop.
    - **View:** Layout, Full Screen, Zoom.
    - **Input:** Device… (choose DeckLink device), Format… (video format/mode).
    - **Analysis:** Scope Type, Analysis Space (gamut for analysis).
    - **Display:** Display Space (gamut for display), Display Options.
    - **Window:** Show Scopes on Second Display (⌘⌥2), Bring All to Front.
    - **Help:** HDR Image Analyzer Pro Help (⌘?), About.

    ---

    ## Input

    1. **Input → Device…** — Select the DeckLink device and re-scan if needed.
    2. **Input → Format…** — Set video mode (resolution, frame rate, pixel format). Supports SD through 4K/12G-SDI.
    3. Four-channel mode uses multiple inputs when available (quad-link / multi-link).

    ---

    ## Scopes & Analysis

    - **Scope types:** Waveform, Vectorscope, Histogram, CIE xy, False Color (when available).
    - **Analysis Space:** Choose the color space used for analysis (e.g. Rec.709, P3, Rec.2020).
    - **Display Space:** Choose the color space used for display (viewing). HDR (PQ/HLG) and SDR spaces are supported.

    ---

    ## Screenshots & Export

    - **Screenshot (Display):** Saves the current display/video image (user is prompted for location).
    - **Screenshot (Scope):** Saves the current scope image.
    - **Copy Screenshot:** Copies the display screenshot to the clipboard.
    - **Timed screenshot:** Start/Stop automatic capture at an interval (e.g. for QC); files go to Documents/HDRAnalyzerScreenshots.
    - **Export:** Use for QC reports, logs, or other export flows as implemented.

    ---

    ## Preferences & Presets

    - **Settings (Preferences):** App preferences (e.g. defaults, display options).
    - **File → Presets…:** Load or save presets to quickly restore device, format, and analysis/display settings.

    ---

    ## Web Remote

    With the app running, open **http://localhost:8765/** to:

    - View the current scope image and input info.
    - Change input source (device/mode) and colorspace when supported.
    - Use the WebSocket control channel for real-time control from scripts or other tools.

    ---

    ## Dolby Vision & Metadata

    When Dolby Vision or HDR10/HDR10+ metadata is present in the signal, the app can parse and display RPU and static/dynamic metadata in the UI. Use the metadata and QC panels to inspect values and alerts.

    ---

    ## Troubleshooting

    - **No video:** Ensure Desktop Video drivers are installed and the DeckLink device is connected. Use Input → Device… to rescan.
    - **Wrong format:** Use Input → Format… to pick the correct resolution and frame rate.
    - **Scopes on second display:** Use Window → Show Scopes on Second Display (⌘⌥2).

    For more detail on phases and features, see the project roadmap and architecture docs in the repository.
    """

    var body: some View {
        ScrollView {
            Text(attributedContent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(minWidth: 520, minHeight: 480)
        .navigationTitle("HDR Image Analyzer Pro Help")
    }

    private var attributedContent: AttributedString {
        do {
            return try AttributedString(markdown: Self.helpContent, options: .init(interpretedSyntax: .full))
        } catch {
            return AttributedString(Self.helpContent)
        }
    }
}
