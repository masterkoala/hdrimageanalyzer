// L1TimelineGraphView.swift
// DV-010: Metadata timeline graph — L1 min/max/avg PQ over time.

import SwiftUI
import AppKit
import Metadata

// MARK: - L1 timeline graph (DV-010)

/// Graph of Dolby Vision L1 values over time: min PQ, max PQ, and avg PQ (normalized 0–1) as three lines.
/// Most recent sample on the right. Uses a fixed sample window (e.g. last N frames).
public struct L1TimelineGraphView: View {
    let samples: [DolbyVisionLevel1Metadata]
    var minColor: Color = Color(nsColor: .systemBlue)
    var maxColor: Color = Color(nsColor: .systemOrange)
    var avgColor: Color = Color(nsColor: .systemGreen)

    public init(
        samples: [DolbyVisionLevel1Metadata],
        minColor: Color = Color(nsColor: .systemBlue),
        maxColor: Color = Color(nsColor: .systemOrange),
        avgColor: Color = Color(nsColor: .systemGreen)
    ) {
        self.samples = samples
        self.minColor = minColor
        self.maxColor = maxColor
        self.avgColor = avgColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("L1 over time (PQ 0–1)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    // Background
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                    if !samples.isEmpty {
                        L1TimelineShape(samples: samples)
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        Text("No L1 data")
                            .font(.caption)
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            HStack(spacing: 16) {
                legendItem(color: minColor, label: "Min PQ")
                legendItem(color: maxColor, label: "Max PQ")
                legendItem(color: avgColor, label: "Avg PQ")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 6)
            Text(label)
        }
    }
}

// MARK: - Shape drawing min/max/avg lines

private struct L1TimelineShape: View {
    let samples: [DolbyVisionLevel1Metadata]

    var body: some View {
        Canvas { context, size in
            guard samples.count >= 2 else { return }
            let w = size.width
            let h = size.height
            let pad: CGFloat = 4
            let plotW = max(0, w - 2 * pad)
            let plotH = max(0, h - 2 * pad)
            let n = CGFloat(samples.count)
            let stepX = n > 1 ? plotW / (n - 1) : 0

            func pathFor(_ values: [Double]) -> Path {
                var path = Path()
                for (i, v) in values.enumerated() {
                    let x = pad + CGFloat(i) * stepX
                    let y = pad + plotH * (1 - CGFloat(v)) // 0 at bottom, 1 at top
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                return path
            }

            let minValues = samples.map(\.minPQNormalized)
            let maxValues = samples.map(\.maxPQNormalized)
            let avgValues = samples.map(\.avgPQNormalized)

            context.stroke(
                pathFor(minValues),
                with: .color(Color(nsColor: .systemBlue)),
                lineWidth: 1.5
            )
            context.stroke(
                pathFor(maxValues),
                with: .color(Color(nsColor: .systemOrange)),
                lineWidth: 1.5
            )
            context.stroke(
                pathFor(avgValues),
                with: .color(Color(nsColor: .systemGreen)),
                lineWidth: 1.5
            )
        }
    }
}
