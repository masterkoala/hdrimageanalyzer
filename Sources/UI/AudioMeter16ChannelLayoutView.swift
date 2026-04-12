import SwiftUI
import Audio

// MARK: - 16-channel meter display layout (AU-009)

/// 16-channel meter display layout using AU-008 AudioMeterView. Shows two rows of 8 channels (ch 1–8, ch 9–16) for readability.
/// Accepts up to 16 channels; pads with zeros if fewer. Optional RMS and channel labels (default "1"…"16").
public struct AudioMeter16ChannelLayoutView: View {
    /// Peak level per channel (linear), up to 16. Padded to 16 with zeros if needed.
    let peakLevels: [Float]
    /// Optional RMS per channel (linear), up to 16.
    let rmsLevels: [Float]?
    /// Show RMS bar when true and rmsLevels non-nil.
    let showRMS: Bool
    /// Channel labels for 1…16 (e.g. ["1","2",…,"16"] or custom). Count padded/truncated to 16.
    let channelLabels: [String]

    private static let channelCount = 16
    private static let channelsPerRow = 8

    public init(
        peakLevels: [Float],
        rmsLevels: [Float]? = nil,
        showRMS: Bool = true,
        channelLabels: [String]? = nil
    ) {
        self.peakLevels = Self.padFloats(peakLevels, count: Self.channelCount)
        self.rmsLevels = rmsLevels.map { Self.padFloats($0, count: Self.channelCount) }
        self.showRMS = showRMS && rmsLevels != nil
        if let labels = channelLabels, labels.count >= Self.channelCount {
            self.channelLabels = Array(labels.prefix(Self.channelCount))
        } else if let labels = channelLabels {
            self.channelLabels = Self.padLabels(labels, count: Self.channelCount)
        } else {
            self.channelLabels = (1...Self.channelCount).map { "\($0)" }
        }
    }

    private static func padFloats(_ source: [Float], count: Int) -> [Float] {
        var result = Array(source.prefix(count))
        result.append(contentsOf: [Float](repeating: 0, count: max(0, count - result.count)))
        return result
    }

    private static func padLabels(_ source: [String], count: Int) -> [String] {
        var result = Array(source.prefix(count))
        for i in result.count..<count {
            result.append("\(i + 1)")
        }
        return result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio level (16ch)")
                .font(.caption)
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                AudioMeterView(
                    peakLevels: Array(peakLevels.prefix(Self.channelsPerRow)),
                    rmsLevels: rmsLevels.map { Array($0.prefix(Self.channelsPerRow)) },
                    showRMS: showRMS,
                    channelLabels: Array(channelLabels.prefix(Self.channelsPerRow))
                )
                AudioMeterView(
                    peakLevels: Array(peakLevels.dropFirst(Self.channelsPerRow)),
                    rmsLevels: rmsLevels.map { Array($0.dropFirst(Self.channelsPerRow)) },
                    showRMS: showRMS,
                    channelLabels: Array(channelLabels.dropFirst(Self.channelsPerRow))
                )
            }
            .frame(minHeight: 120)
        }
        .padding(8)
        .background(Color.primary.opacity(0.03))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Preview

#if DEBUG
struct AudioMeter16ChannelLayoutView_Previews: PreviewProvider {
    static var previews: some View {
        AudioMeter16ChannelLayoutView(
            peakLevels: (0..<16).map { _ in Float.random(in: 0.05...0.9) },
            rmsLevels: (0..<16).map { _ in Float.random(in: 0.03...0.7) },
            showRMS: true
        )
        .frame(width: 520, height: 280)
        .padding()
    }
}
#endif
