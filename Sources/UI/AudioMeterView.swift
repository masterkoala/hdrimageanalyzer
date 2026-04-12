import SwiftUI
import Audio

// MARK: - Linear to dB

/// Convert linear amplitude [0, 1] to dB (0 dB = full scale). Returns -60 for zero/silence for display purposes.
private func linearToDB(_ linear: Float) -> Float {
    let clamped = max(linear, 1e-6)
    return 20 * log10(clamped)
}

/// dB scale range for meter (e.g. -60 to 0 dB).
private let meterDBMin: Float = -60
private let meterDBMax: Float = 0

/// Tick marks for dB scale (every 6 dB for readability).
private let dbTicks: [Int] = [-60, -48, -36, -24, -12, -6, 0]

// MARK: - Audio meter view (AU-008)

/// Audio meter UI: vertical bar(s) with dB scale and tick marks. Binds to AU-002 peak (optional AU-003 RMS).
/// Per-channel levels in linear scale [0, 1]; optionally show RMS as secondary bar.
public struct AudioMeterView: View {
    /// Peak level per channel (linear). From PeakLevelMeter.currentPeakLevels (AU-002).
    let peakLevels: [Float]
    /// Optional RMS per channel (linear). From RMSLevelMeter.currentRMSLevels (AU-003).
    let rmsLevels: [Float]?
    /// Show RMS bar when true and rmsLevels non-nil.
    let showRMS: Bool
    /// Channel labels (e.g. ["L", "R"] or ["1"..."8"]).
    let channelLabels: [String]

    public init(
        peakLevels: [Float],
        rmsLevels: [Float]? = nil,
        showRMS: Bool = true,
        channelLabels: [String]? = nil
    ) {
        self.peakLevels = peakLevels
        self.rmsLevels = rmsLevels
        self.showRMS = showRMS && rmsLevels != nil
        let n = peakLevels.count
        if let labels = channelLabels, labels.count >= n {
            self.channelLabels = Array(labels.prefix(n))
        } else {
            self.channelLabels = (0..<n).map { "\($0 + 1)" }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio level")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(alignment: .bottom, spacing: 12) {
                dBScaleView()
                HStack(spacing: 6) {
                    ForEach(Array(peakLevels.indices), id: \.self) { index in
                        ChannelMeterBar(
                            peakLinear: index < peakLevels.count ? peakLevels[index] : 0,
                            rmsLinear: (showRMS && rmsLevels != nil && index < (rmsLevels?.count ?? 0)) ? rmsLevels![index] : nil,
                            label: index < channelLabels.count ? channelLabels[index] : "\(index + 1)"
                        )
                    }
                }
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

// MARK: - dB scale (tick marks + labels)

private func dbToFraction(_ db: Int) -> CGFloat {
    let f = Float(db - Int(meterDBMin)) / (meterDBMax - meterDBMin)
    return CGFloat(max(0, min(1, f)))
}

private struct dBScaleView: View {
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .leading) {
                ForEach(dbTicks, id: \.self) { db in
                    let fraction = dbToFraction(db)
                    let y = h * (1 - fraction)
                    HStack(spacing: 4) {
                        Text("\(db)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Rectangle()
                            .fill(Color.primary.opacity(0.25))
                            .frame(width: 4, height: 1)
                    }
                    .position(x: 16, y: y)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 32)
    }
}

// MARK: - Single channel vertical bar

private struct ChannelMeterBar: View {
    let peakLinear: Float
    let rmsLinear: Float?
    let label: String

    private var peakDB: Float { linearToDB(peakLinear) }
    private var rmsDB: Float? { rmsLinear.map { linearToDB($0) } }

    private func fraction(for dB: Float, dbRange: Float) -> CGFloat {
        let f = (dB - meterDBMin) / dbRange
        return CGFloat(max(0, min(1, f)))
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let h = geo.size.height
                let dbRange = meterDBMax - meterDBMin
                ZStack(alignment: .bottom) {
                    // Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                    // Peak fill (green → yellow → red by segment)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(peakGradient)
                        .frame(height: h * fraction(for: peakDB, dbRange: dbRange))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    // Optional RMS indicator (horizontal line at RMS level)
                    if let rms = rmsDB, rms > meterDBMin {
                        Rectangle()
                            .fill(Color.white.opacity(0.7))
                            .frame(height: 2)
                            .frame(height: h * fraction(for: rms, dbRange: dbRange), alignment: .bottom)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(minWidth: 20)
    }

    private var peakGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.green.opacity(0.9),
                Color.yellow.opacity(0.9),
                Color.orange,
                Color.red
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }
}

// MARK: - Preview

#if DEBUG
struct AudioMeterView_Previews: PreviewProvider {
    static var previews: some View {
        AudioMeterView(
            peakLevels: [0.25, 0.5, 0.8, 0.1],
            rmsLevels: [0.2, 0.4, 0.6, 0.08],
            showRMS: true,
            channelLabels: ["L", "R", "3", "4"]
        )
        .frame(width: 280, height: 160)
        .padding()
    }
}
#endif
