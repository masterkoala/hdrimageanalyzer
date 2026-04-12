import SwiftUI
import Common

// MARK: - Signal status for status bar LED

/// Represents the signal connection status displayed as an LED indicator in the status bar.
public enum SignalStatus: String {
    case live         = "Live"
    case unstable     = "Unstable"
    case noSignal     = "No Signal"
    case disconnected = "Disconnected"

    /// LED color corresponding to the signal state.
    public var color: Color {
        switch self {
        case .live:         return Color(red: 0.20, green: 0.85, blue: 0.30)
        case .unstable:     return Color(red: 0.95, green: 0.80, blue: 0.15)
        case .noSignal:     return Color(red: 0.90, green: 0.22, blue: 0.20)
        case .disconnected: return Color(red: 0.45, green: 0.45, blue: 0.48)
        }
    }

    /// SF Symbol for the signal state.
    public var icon: String {
        switch self {
        case .live:         return "antenna.radiowaves.left.and.right"
        case .unstable:     return "exclamationmark.triangle"
        case .noSignal:     return "antenna.radiowaves.left.and.right.slash"
        case .disconnected: return "cable.connector.horizontal"
        }
    }
}

// MARK: - ToolbarButton

/// Reusable compact toolbar button with SF Symbol icon, optional label, hover highlight,
/// and active/selected state using AJATheme accent color. Designed for 28x28 hit targets.
public struct ToolbarButton: View {
    let icon: String
    var label: String?
    var isActive: Bool = false
    var showLabelOnHover: Bool = true
    var action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        icon: String,
        label: String? = nil,
        isActive: Bool = false,
        showLabelOnHover: Bool = true,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.isActive = isActive
        self.showLabelOnHover = showLabelOnHover
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AJATheme.accent : (isHovered ? AJATheme.primaryText : AJATheme.secondaryText))

                if let label, (!showLabelOnHover || isHovered) {
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isActive ? AJATheme.accent : AJATheme.secondaryText)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                }
            }
            .frame(minWidth: 28, minHeight: 28)
            .padding(.horizontal, label != nil && (!showLabelOnHover || isHovered) ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(buttonBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(label ?? "")
    }

    private var buttonBackground: Color {
        if isActive {
            return AJATheme.accent.opacity(0.18)
        } else if isHovered {
            return AJATheme.primaryText.opacity(0.08)
        }
        return Color.clear
    }
}

// MARK: - ToolbarDivider

/// Thin vertical separator for use between toolbar button groups.
public struct ToolbarDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(AJATheme.divider)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 4)
    }
}

// MARK: - ScopeToolbarView

/// Professional compact toolbar for the HDR Analyzer main window. Provides layout mode
/// selection, capture controls, screenshot, settings, and full-screen toggles.
/// Height: ~36px with dark background and subtle bottom border.
public struct ScopeToolbarView: View {
    @ObservedObject var layoutManager: FlexibleLayoutManager

    /// Whether capture is currently recording.
    @Binding var isCapturing: Bool
    /// Whether the window is in full-screen mode.
    @Binding var isFullScreen: Bool

    /// Action callbacks.
    var onToggleCapture: () -> Void
    var onScreenshot: () -> Void
    var onOpenSettings: () -> Void
    var onToggleFullScreen: () -> Void

    public init(
        layoutManager: FlexibleLayoutManager,
        isCapturing: Binding<Bool>,
        isFullScreen: Binding<Bool>,
        onToggleCapture: @escaping () -> Void,
        onScreenshot: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onToggleFullScreen: @escaping () -> Void
    ) {
        self.layoutManager = layoutManager
        self._isCapturing = isCapturing
        self._isFullScreen = isFullScreen
        self.onToggleCapture = onToggleCapture
        self.onScreenshot = onScreenshot
        self.onOpenSettings = onOpenSettings
        self.onToggleFullScreen = onToggleFullScreen
    }

    public var body: some View {
        HStack(spacing: 0) {
            // MARK: Left section -- App identity
            appIdentitySection
                .frame(minWidth: 140, alignment: .leading)

            ToolbarDivider()

            Spacer(minLength: 4)

            // MARK: Center section -- Layout mode buttons
            LayoutToolbarView(layoutManager: layoutManager)

            Spacer(minLength: 4)

            ToolbarDivider()

            // MARK: Right section -- Quick actions
            quickActionsSection
                .frame(alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(AJATheme.panelBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AJATheme.border.opacity(0.6))
                .frame(height: 1)
        }
    }

    // MARK: - App identity (left)

    private var appIdentitySection: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AJATheme.accent)

            Text("HDR Analyzer Pro")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AJATheme.primaryText)
                .lineLimit(1)
        }
    }

    // MARK: - Quick actions (right)

    private var quickActionsSection: some View {
        HStack(spacing: 2) {
            // Capture start/stop toggle
            ToolbarButton(
                icon: isCapturing ? "record.circle.fill" : "record.circle",
                label: isCapturing ? "Stop" : "Capture",
                isActive: isCapturing,
                showLabelOnHover: true
            ) {
                onToggleCapture()
            }
            .overlay(alignment: .topTrailing) {
                if isCapturing {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 4)
                        .transition(.scale.combined(with: .opacity))
                }
            }

            // Screenshot
            ToolbarButton(
                icon: "camera",
                label: "Screenshot",
                showLabelOnHover: true
            ) {
                onScreenshot()
            }

            ToolbarDivider()

            // Settings gear
            ToolbarButton(
                icon: "gearshape",
                label: "Settings",
                showLabelOnHover: true
            ) {
                onOpenSettings()
            }

            // Full-screen toggle
            ToolbarButton(
                icon: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                label: isFullScreen ? "Exit Full Screen" : "Full Screen",
                isActive: isFullScreen,
                showLabelOnHover: true
            ) {
                onToggleFullScreen()
            }
        }
    }
}

// MARK: - ScopeHeaderView

/// Compact header for individual scope panels. Shows scope type icon and name,
/// with optional close/fullscreen/settings buttons revealed on hover.
/// Height: 20px with slightly elevated background.
public struct ScopeHeaderView: View {
    let content: QuadrantContent
    var onClose: (() -> Void)?
    var onFullScreen: (() -> Void)?
    var onSettings: (() -> Void)?

    @State private var isHovered: Bool = false

    public init(
        content: QuadrantContent,
        onClose: (() -> Void)? = nil,
        onFullScreen: (() -> Void)? = nil,
        onSettings: (() -> Void)? = nil
    ) {
        self.content = content
        self.onClose = onClose
        self.onFullScreen = onFullScreen
        self.onSettings = onSettings
    }

    public var body: some View {
        HStack(spacing: 4) {
            // Scope type icon
            Image(systemName: content.iconName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(AJATheme.accent.opacity(0.8))

            // Scope name
            Text(content.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AJATheme.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 0)

            // Hover-revealed action buttons
            if isHovered {
                HStack(spacing: 2) {
                    if let onSettings {
                        scopeHeaderButton(icon: "slider.horizontal.3", action: onSettings)
                    }
                    if let onFullScreen {
                        scopeHeaderButton(icon: "arrow.up.left.and.arrow.down.right", action: onFullScreen)
                    }
                    if let onClose {
                        scopeHeaderButton(icon: "xmark", action: onClose)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(AJATheme.elevatedBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AJATheme.border.opacity(0.4))
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private func scopeHeaderButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(AJATheme.tertiaryText)
                .frame(width: 16, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AJATheme.primaryText.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - EnhancedStatusBarView

/// Professional status bar replacing CaptureStatusBarView. Provides signal status LED,
/// format/frame-rate/timecode/color-space readout, and CPU/GPU/memory/FPS performance indicators.
/// Uses monospaced font for timecode and numeric readouts.
public struct EnhancedStatusBarView: View {
    // MARK: Signal info

    var signalStatus: SignalStatus
    var formatString: String
    var frameRateString: String
    var timecodeString: String
    var colorSpaceString: String

    // MARK: Performance info

    var cpuUsage: Double
    var gpuUsage: Double
    var memoryUsageMB: Double
    var scopeFPS: Double

    public init(
        signalStatus: SignalStatus = .disconnected,
        formatString: String = "--",
        frameRateString: String = "--",
        timecodeString: String = "00:00:00:00",
        colorSpaceString: String = "--",
        cpuUsage: Double = 0,
        gpuUsage: Double = 0,
        memoryUsageMB: Double = 0,
        scopeFPS: Double = 0
    ) {
        self.signalStatus = signalStatus
        self.formatString = formatString
        self.frameRateString = frameRateString
        self.timecodeString = timecodeString
        self.colorSpaceString = colorSpaceString
        self.cpuUsage = cpuUsage
        self.gpuUsage = gpuUsage
        self.memoryUsageMB = memoryUsageMB
        self.scopeFPS = scopeFPS
    }

    public var body: some View {
        HStack(spacing: 0) {
            // MARK: Left -- Signal status LED
            signalLEDSection

            Spacer(minLength: 4)

            // MARK: Center -- Format, frame rate, timecode, color space
            centerInfoSection

            Spacer(minLength: 4)

            // MARK: Right -- Performance indicators
            performanceSection
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(statusBarBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AJATheme.border.opacity(0.3))
                .frame(height: 0.5)
        }
    }

    // MARK: - Signal LED

    private var signalLEDSection: some View {
        HStack(spacing: 5) {
            // LED dot with glow
            Circle()
                .fill(signalStatus.color)
                .frame(width: 7, height: 7)
                .shadow(color: signalStatus.color.opacity(0.6), radius: signalStatus == .live ? 3 : 0)
                .overlay(
                    Circle()
                        .stroke(signalStatus.color.opacity(0.3), lineWidth: 1)
                        .frame(width: 11, height: 11)
                        .opacity(signalStatus == .live ? 1 : 0)
                )

            Image(systemName: signalStatus.icon)
                .font(.system(size: 9))
                .foregroundStyle(signalStatus.color.opacity(0.8))

            Text(signalStatus.rawValue)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(signalStatus.color)
        }
    }

    // MARK: - Center info

    private var centerInfoSection: some View {
        HStack(spacing: 12) {
            statusField(label: "FMT", value: formatString)
            statusDivider
            statusField(label: "FPS", value: frameRateString)
            statusDivider
            // Timecode uses monospaced for alignment
            HStack(spacing: 3) {
                Text("TC")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(AJATheme.tertiaryText)
                Text(timecodeString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(AJATheme.primaryText)
            }
            statusDivider
            statusField(label: "CS", value: colorSpaceString)
        }
    }

    // MARK: - Performance indicators

    private var performanceSection: some View {
        HStack(spacing: 10) {
            performanceGauge(label: "CPU", value: cpuUsage, maxValue: 100, unit: "%")
            performanceGauge(label: "GPU", value: gpuUsage, maxValue: 100, unit: "%")
            performanceGauge(label: "MEM", value: memoryUsageMB, maxValue: 16384, unit: "MB")
            performanceGauge(label: "SCF", value: scopeFPS, maxValue: 120, unit: "fps", showBar: false)
        }
    }

    // MARK: - Helpers

    private func statusField(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(AJATheme.tertiaryText)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(AJATheme.secondaryText)
        }
    }

    private var statusDivider: some View {
        Rectangle()
            .fill(AJATheme.divider.opacity(0.5))
            .frame(width: 1, height: 10)
    }

    private func performanceGauge(label: String, value: Double, maxValue: Double, unit: String, showBar: Bool = true) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(AJATheme.tertiaryText)

            if showBar {
                // Micro bar gauge
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(AJATheme.primaryText.opacity(0.08))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(gaugeColor(value: value, maxValue: maxValue))
                            .frame(width: max(1, geo.size.width * min(value / maxValue, 1.0)))
                    }
                }
                .frame(width: 24, height: 4)
            }

            Text(formatGaugeValue(value: value, unit: unit))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(AJATheme.secondaryText)
                .frame(minWidth: 28, alignment: .trailing)
        }
    }

    private func gaugeColor(value: Double, maxValue: Double) -> Color {
        let ratio = value / maxValue
        if ratio > 0.85 {
            return Color(red: 0.90, green: 0.22, blue: 0.20) // red
        } else if ratio > 0.65 {
            return Color(red: 0.95, green: 0.75, blue: 0.15) // yellow
        }
        return Color(red: 0.20, green: 0.78, blue: 0.35) // green
    }

    private func formatGaugeValue(value: Double, unit: String) -> String {
        switch unit {
        case "%":
            return String(format: "%.0f%%", value)
        case "MB":
            if value >= 1024 {
                return String(format: "%.1fG", value / 1024)
            }
            return String(format: "%.0fM", value)
        case "fps":
            return String(format: "%.0f", value)
        default:
            return String(format: "%.0f", value)
        }
    }

    /// Subtle gradient background matching the status bar aesthetic.
    private var statusBarBackground: some View {
        LinearGradient(
            colors: [
                AJATheme.statusBarBackground,
                AJATheme.statusBarBackground.opacity(0.95)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Preview helpers

#if DEBUG
struct ScopeToolbarView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 0) {
            ScopeToolbarView(
                layoutManager: FlexibleLayoutManager(),
                isCapturing: .constant(false),
                isFullScreen: .constant(false),
                onToggleCapture: {},
                onScreenshot: {},
                onOpenSettings: {},
                onToggleFullScreen: {}
            )

            ScopeToolbarView(
                layoutManager: FlexibleLayoutManager(),
                isCapturing: .constant(true),
                isFullScreen: .constant(false),
                onToggleCapture: {},
                onScreenshot: {},
                onOpenSettings: {},
                onToggleFullScreen: {}
            )

            Spacer()

            EnhancedStatusBarView(
                signalStatus: .live,
                formatString: "3840x2160",
                frameRateString: "59.94",
                timecodeString: "01:23:45:12",
                colorSpaceString: "Rec.2020 PQ",
                cpuUsage: 34.5,
                gpuUsage: 62.1,
                memoryUsageMB: 2048,
                scopeFPS: 59.9
            )

            EnhancedStatusBarView(
                signalStatus: .noSignal,
                formatString: "--",
                frameRateString: "--",
                timecodeString: "00:00:00:00",
                colorSpaceString: "--",
                cpuUsage: 5,
                gpuUsage: 2,
                memoryUsageMB: 512,
                scopeFPS: 0
            )
        }
        .frame(width: 900, height: 400)
        .background(AJATheme.windowBackground)
    }
}

struct ScopeHeaderView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 8) {
            ForEach(QuadrantContent.allCases, id: \.rawValue) { content in
                ScopeHeaderView(
                    content: content,
                    onClose: { },
                    onFullScreen: { },
                    onSettings: { }
                )
                .frame(width: 300)
            }
        }
        .padding()
        .background(AJATheme.panelBackground)
    }
}
#endif
