// QCDashboardPanelView.swift
// QC-010: QC dashboard panel in main UI — violation counts and alerts.

import SwiftUI
import AppKit
import Logging

// MARK: - QC Dashboard Panel (QC-010)

/// Panel showing QC violation counts by event kind and recent alerts. Uses QCEventBuffer.snapshot() (QC-001, QC-002).
/// Refreshes periodically so new events appear without leaving the view.
public struct QCDashboardPanelView: View {
    private static let refreshInterval: TimeInterval = 1.0
    private static let maxAlerts = 25

    public init() {}

    public var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
            let events = QCEventBuffer.snapshot()
            let counts = Self.violationCounts(events)
            let alerts = Array(events.suffix(Self.maxAlerts).reversed())

            VStack(alignment: .leading, spacing: 12) {
                Text("QC Dashboard")
                    .font(.headline)
                    .foregroundStyle(AJATheme.secondaryText)

                // Violation counts by kind
                violationCountsSection(counts: counts, total: events.count)
                Divider()
                // Recent alerts
                alertsSection(alerts: alerts)
            }
        }
        .frame(minWidth: 280)
    }

    private static func violationCounts(_ events: [QCEvent]) -> [(kind: QCEventKind, count: Int)] {
        var dict: [QCEventKind: Int] = [:]
        for event in events {
            dict[event.kind, default: 0] += 1
        }
        return dict.sorted { $0.value > $1.value }.map { (kind: $0.key, count: $0.value) }
    }

    @ViewBuilder
    private func violationCountsSection(counts: [(kind: QCEventKind, count: Int)], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Violation counts")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("Total: \(total)")
                    .font(.caption)
                    .foregroundStyle(AJATheme.secondaryText)
            }
            if counts.isEmpty {
                Text("No QC events this session")
                    .font(.caption)
                    .foregroundStyle(AJATheme.tertiaryText)
            } else {
                ForEach(counts, id: \.kind.rawValue) { item in
                    HStack {
                        Text(item.kind.displayName)
                            .font(.caption)
                        Spacer()
                        Text("\(item.count)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(severityColor(for: item.count))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func alertsSection(alerts: [QCEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent alerts")
                .font(.subheadline)
                .fontWeight(.medium)
            if alerts.isEmpty {
                Text("No alerts")
                    .font(.caption)
                    .foregroundStyle(AJATheme.tertiaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(alerts.enumerated()), id: \.offset) { _, event in
                            alertRow(event)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private func alertRow(_ event: QCEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(severityColor(for: event.severity))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.kind.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(event.description)
                    .font(.caption2)
                    .foregroundStyle(AJATheme.secondaryText)
                    .lineLimit(2)
                if let tc = event.timecode, !tc.isEmpty {
                    Text(tc)
                        .font(.caption2)
                        .foregroundStyle(AJATheme.tertiaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(AJATheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func severityColor(for severity: QCEventSeverity) -> Color {
        switch severity {
        case .info: return Color.blue
        case .warning: return Color.orange
        case .error: return Color.red
        case .critical: return Color.purple
        }
    }

    private func severityColor(for count: Int) -> Color {
        if count == 0 { return .primary }
        if count > 100 { return .red }
        if count > 10 { return .orange }
        return .blue
    }
}
