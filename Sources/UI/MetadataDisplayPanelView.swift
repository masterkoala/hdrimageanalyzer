// MetadataDisplayPanelView.swift
// DV-009: Metadata display panel for DV/HDR10 — L1 (min/max/avg PQ), L2 (trims), HDR10 static (ST 2086).
// DV-010: L1 timeline graph (min/max/avg PQ over time).

import SwiftUI
import AppKit
import Metadata

// MARK: - Metadata display panel (DV-009, DV-010)

/// Panel showing Dolby Vision L1/L2 and HDR10 static metadata from DV-004, DV-005, DV-002.
/// DV-010: Optional L1 history for timeline graph (min/max/avg PQ over time).
/// Displays "—" when a value is nil (no metadata or not present).
public struct MetadataDisplayPanelView: View {
    let level1: DolbyVisionLevel1Metadata?
    let level2: DolbyVisionLevel2Metadata?
    let hdr10Static: HDR10StaticMetadata?
    /// DV-010: History of L1 samples for timeline graph; empty or nil hides the graph.
    let l1History: [DolbyVisionLevel1Metadata]?

    public init(
        level1: DolbyVisionLevel1Metadata? = nil,
        level2: DolbyVisionLevel2Metadata? = nil,
        hdr10Static: HDR10StaticMetadata? = nil,
        l1History: [DolbyVisionLevel1Metadata]? = nil
    ) {
        self.level1 = level1
        self.level2 = level2
        self.hdr10Static = hdr10Static
        self.l1History = l1History
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DV / HDR10 Metadata")
                .font(.headline)
                .foregroundStyle(AJATheme.secondaryText)

            // Dolby Vision Level 1 (DV-004): min/max/avg PQ
            sectionHeader("Dolby Vision L1 (PQ per frame)")
            if let l1 = level1 {
                HStack(alignment: .top, spacing: 24) {
                    metaRow("Min PQ", value: String(format: "%.4f", l1.minPQNormalized), raw: "\(l1.minPQRaw)")
                    metaRow("Max PQ", value: String(format: "%.4f", l1.maxPQNormalized), raw: "\(l1.maxPQRaw)")
                    metaRow("Avg PQ", value: String(format: "%.4f", l1.avgPQNormalized), raw: "\(l1.avgPQRaw)")
                }
            } else {
                Text("—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(AJATheme.tertiaryText)
            }

            // DV-010: L1 timeline graph (min/max/avg PQ over time)
            if let history = l1History, !history.isEmpty {
                L1TimelineGraphView(samples: history)
                    .frame(minHeight: 120)
            }

            Divider()

            // Dolby Vision Level 2 (DV-005): trims per target
            sectionHeader("Dolby Vision L2 (target trims)")
            if let l2 = level2, !l2.targetTrims.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(l2.targetTrims.enumerated()), id: \.offset) { index, trim in
                        HStack(spacing: 16) {
                            Text("Target \(index + 1)")
                                .font(.caption)
                                .foregroundStyle(AJATheme.secondaryText)
                                .frame(width: 60, alignment: .leading)
                            metaRow("Slope", value: String(format: "%.4f", trim.trimSlopeNormalized), raw: "\(trim.trimSlopeRaw)")
                            metaRow("Offset", value: String(format: "%.4f", trim.trimOffsetNormalized), raw: "\(trim.trimOffsetRaw)")
                        }
                    }
                }
            } else {
                Text("—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(AJATheme.tertiaryText)
            }

            Divider()

            // HDR10 static (DV-002): ST 2086
            sectionHeader("HDR10 static (ST 2086)")
            if let hdr = hdr10Static {
                VStack(alignment: .leading, spacing: 8) {
                    metaRow("Max mastering luminance", value: "\(hdr.maxDisplayMasteringLuminance) cd/m²", raw: nil)
                    metaRow("Min mastering luminance", value: String(format: "%.4f cd/m²", hdr.minDisplayMasteringLuminanceCdM2), raw: nil)
                    HStack(spacing: 24) {
                        Text("Primaries / White")
                            .font(.caption)
                            .foregroundStyle(AJATheme.secondaryText)
                        Text("R(\(fmt(hdr.displayPrimaries.redX.value)),\(fmt(hdr.displayPrimaries.redY.value))) G(\(fmt(hdr.displayPrimaries.greenX.value)),\(fmt(hdr.displayPrimaries.greenY.value))) B(\(fmt(hdr.displayPrimaries.blueX.value)),\(fmt(hdr.displayPrimaries.blueY.value))) W(\(fmt(hdr.whitePoint.x.value)),\(fmt(hdr.whitePoint.y.value)))")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            } else {
                Text("—")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(AJATheme.tertiaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AJATheme.panelBackground)
        .cornerRadius(8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(AJATheme.secondaryText)
    }

    private func metaRow(_ label: String, value: String, raw: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(AJATheme.tertiaryText)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AJATheme.primaryText)
            if let r = raw {
                Text("raw \(r)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AJATheme.tertiaryText)
            }
        }
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.4f", v)
    }
}
