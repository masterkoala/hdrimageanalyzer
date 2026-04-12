import SwiftUI
import Capture

/// Status bar (UI-012): format, frame rate, timecode (DL-008), device info. Shown at bottom of main window.
/// PERF-003: Observes CaptureMetadataState (volatile) instead of CapturePreviewState to avoid
/// triggering re-evaluation of the entire view hierarchy on metadata updates.
public struct CaptureStatusBarView: View {
    @ObservedObject private var metadata: CaptureMetadataState
    private let captureState: CapturePreviewState

    public init(captureState: CapturePreviewState) {
        self.captureState = captureState
        self._metadata = ObservedObject(wrappedValue: captureState.metadata)
    }

    private var formatString: String {
        if let w = metadata.currentFormatWidth, let h = metadata.currentFormatHeight {
            return "\(w)×\(h)"
        }
        guard let mode = captureState.selectedMode else { return "—" }
        return "\(mode.width)×\(mode.height)"
    }

    private var frameRateString: String {
        if let fps = metadata.currentFrameRate {
            return formatFPS(fps)
        }
        guard let mode = captureState.selectedMode else { return "—" }
        return formatFPS(mode.frameRate)
    }

    private func formatFPS(_ fps: Double) -> String {
        if fps == fps.rounded() {
            return "\(Int(fps)) fps"
        }
        return String(format: "%.2f fps", fps)
    }

    private var timecodeString: String {
        metadata.currentTimecode ?? "—"
    }

    private var deviceString: String {
        captureState.selectedDeviceInfo?.displayName ?? "No device"
    }

    public var body: some View {
        HStack(spacing: 16) {
            statusItem(label: "Format", value: formatString)
            Divider()
                .frame(height: 14)
            statusItem(label: "Frame rate", value: frameRateString)
            Divider()
                .frame(height: 14)
            statusItem(label: "Timecode", value: timecodeString)
            Divider()
                .frame(height: 14)
            statusItem(label: "Device", value: deviceString)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(AJATheme.secondaryText)
        .background(AJATheme.statusBarBackground)
    }

    private func statusItem(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .foregroundStyle(AJATheme.tertiaryText)
            Text(value)
                .foregroundStyle(AJATheme.secondaryText)
        }
    }
}
