import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import Common

// MARK: - Layout mode enum (UI-020)

/// Defines the available layout configurations for the scope panel grid.
/// Each mode specifies how many panels are displayed and their spatial arrangement.
public enum LayoutMode: String, CaseIterable, Codable {
    case single       = "single"
    case sideBySide   = "sideBySide"
    case stacked      = "stacked"
    case quad         = "quad"
    case tripleLeft   = "tripleLeft"
    case tripleTop    = "tripleTop"
    case grid3x1      = "grid3x1"
    case grid1x3      = "grid1x3"
    case sixPack      = "sixPack"

    /// Human-readable name for display in menus and tooltips.
    public var displayName: String {
        switch self {
        case .single:     return "Single"
        case .sideBySide: return "Side by Side"
        case .stacked:    return "Stacked"
        case .quad:       return "Quad (2x2)"
        case .tripleLeft: return "Triple Left"
        case .tripleTop:  return "Triple Top"
        case .grid3x1:    return "3 Across"
        case .grid1x3:    return "3 Stacked"
        case .sixPack:    return "Six Pack (3x2)"
        }
    }

    /// SF Symbol name for toolbar icon representation.
    public var icon: String {
        switch self {
        case .single:     return "square"
        case .sideBySide: return "rectangle.split.2x1"
        case .stacked:    return "rectangle.split.1x2"
        case .quad:       return "rectangle.split.2x2"
        case .tripleLeft: return "rectangle.leadinghalf.inset.filled.arrow.leading"
        case .tripleTop:  return "rectangle.tophalf.inset.filled"
        case .grid3x1:    return "rectangle.split.3x1"
        case .grid1x3:    return "rectangle.split.1x2.fill"
        case .sixPack:    return "rectangle.split.3x3"
        }
    }

    /// Number of distinct panels this layout contains.
    public var panelCount: Int {
        switch self {
        case .single:     return 1
        case .sideBySide: return 2
        case .stacked:    return 2
        case .quad:       return 4
        case .tripleLeft: return 3
        case .tripleTop:  return 3
        case .grid3x1:    return 3
        case .grid1x3:    return 3
        case .sixPack:    return 6
        }
    }
}

// MARK: - Layout panel model

/// Represents a single panel within a flexible layout, including its content assignment and
/// proportional sizing within the overall grid.
public struct LayoutPanel: Identifiable, Codable, Equatable {
    public let id: Int
    public var index: Int
    public var content: QuadrantContent
    public var relativeWidth: CGFloat
    public var relativeHeight: CGFloat

    public init(index: Int, content: QuadrantContent, relativeWidth: CGFloat = 1.0, relativeHeight: CGFloat = 1.0) {
        self.id = index
        self.index = index
        self.content = content
        self.relativeWidth = relativeWidth
        self.relativeHeight = relativeHeight
    }
}

// MARK: - Panel drag payload (UI-020)

/// Transferable payload for drag-to-swap between panels in the flexible layout.
public struct PanelDragItem: Codable, Transferable {
    public let panelIndex: Int

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

// MARK: - Flexible layout manager (UI-020)

/// Central manager for the flexible layout system. Maintains the current layout mode, panel
/// configuration, and display preferences. Publishes changes for SwiftUI observation and
/// persists state to UserDefaults.
public final class FlexibleLayoutManager: ObservableObject {
    // MARK: Published state

    @Published public var currentLayout: LayoutMode = .quad
    @Published public var panels: [LayoutPanel] = []
    @Published public var showScopeLabels: Bool = true
    @Published public var showScopeControls: Bool = true
    @Published public var panelSpacing: CGFloat = 4
    /// Custom split ratios for resizable layouts, keyed by layout-specific identifier.
    @Published public var splitRatios: [String: CGFloat] = [:]

    // MARK: UserDefaults keys

    private enum DefaultsKey {
        static let layoutMode = "HDRApp.FlexibleLayout.Mode"
        static let panels = "HDRApp.FlexibleLayout.Panels"
        static let showLabels = "HDRApp.FlexibleLayout.ShowLabels"
        static let showControls = "HDRApp.FlexibleLayout.ShowControls"
        static let spacing = "HDRApp.FlexibleLayout.Spacing"
        static let splitRatios = "HDRApp.FlexibleLayout.SplitRatios"
    }

    // MARK: Initialization

    public init() {
        restoreFromDefaults()
        if panels.isEmpty {
            applyLayout(.quad)
        }
    }

    // MARK: - Layout application

    /// Applies the given layout mode, rebuilding the panel array with default content assignments
    /// appropriate for the panel count. Persists the new state.
    public func applyLayout(_ mode: LayoutMode) {
        currentLayout = mode
        panels = Self.defaultPanels(for: mode)
        saveToDefaults()
    }

    /// Returns a binding to the content of the panel at the given index. Falls back to the first
    /// panel if the index is out of range.
    public func panelContent(at index: Int) -> Binding<QuadrantContent> {
        Binding<QuadrantContent>(
            get: { [weak self] in
                guard let self, index >= 0, index < self.panels.count else {
                    return .video
                }
                return self.panels[index].content
            },
            set: { [weak self] newValue in
                guard let self, index >= 0, index < self.panels.count else { return }
                self.panels[index].content = newValue
                self.saveToDefaults()
            }
        )
    }

    /// Returns a human-readable description of the current layout configuration.
    public func layoutDescription() -> String {
        let names = panels.map { $0.content.displayName }
        return "\(currentLayout.displayName) (\(panels.count) panels): \(names.joined(separator: ", "))"
    }

    /// Swaps the content between two panels identified by index. No-op if indices are equal or
    /// out of range.
    public func swapPanels(source: Int, target: Int) {
        guard source != target,
              source >= 0, source < panels.count,
              target >= 0, target < panels.count else { return }
        let temp = panels[source].content
        panels[source].content = panels[target].content
        panels[target].content = temp
        saveToDefaults()
    }

    /// Set of scope types currently visible across all panels, for performance optimization
    /// (only compute scopes that are actually displayed).
    public var visibleScopeTypes: Set<String> {
        var result = Set<String>()
        for panel in panels {
            if panel.content != .video {
                result.insert(panel.content.rawValue)
            }
        }
        return result
    }

    // MARK: - Split ratio helpers

    /// Get a split ratio with a default value.
    public func splitRatio(for key: String, default defaultValue: CGFloat = 0.5) -> CGFloat {
        splitRatios[key] ?? defaultValue
    }

    /// Set a split ratio, clamped to [0.15, 0.85].
    public func setSplitRatio(for key: String, value: CGFloat) {
        splitRatios[key] = max(0.15, min(0.85, value))
        saveToDefaults()
    }

    // MARK: - Default panel configurations

    /// Generates the default panel array for a given layout mode, assigning sensible default
    /// content types (video, waveform, vectorscope, histogram, parade, ciexy) in rotation.
    private static func defaultPanels(for mode: LayoutMode) -> [LayoutPanel] {
        let defaultContents: [QuadrantContent] = [.video, .waveform, .vectorscope, .histogram, .parade, .ciexy]

        switch mode {
        case .single:
            return [
                LayoutPanel(index: 0, content: .video, relativeWidth: 1.0, relativeHeight: 1.0)
            ]

        case .sideBySide:
            return [
                LayoutPanel(index: 0, content: .video, relativeWidth: 0.5, relativeHeight: 1.0),
                LayoutPanel(index: 1, content: .waveform, relativeWidth: 0.5, relativeHeight: 1.0)
            ]

        case .stacked:
            return [
                LayoutPanel(index: 0, content: .video, relativeWidth: 1.0, relativeHeight: 0.5),
                LayoutPanel(index: 1, content: .waveform, relativeWidth: 1.0, relativeHeight: 0.5)
            ]

        case .quad:
            return [
                LayoutPanel(index: 0, content: .video, relativeWidth: 0.5, relativeHeight: 0.5),
                LayoutPanel(index: 1, content: .waveform, relativeWidth: 0.5, relativeHeight: 0.5),
                LayoutPanel(index: 2, content: .histogram, relativeWidth: 0.5, relativeHeight: 0.5),
                LayoutPanel(index: 3, content: .vectorscope, relativeWidth: 0.5, relativeHeight: 0.5)
            ]

        case .tripleLeft:
            return [
                LayoutPanel(index: 0, content: .video, relativeWidth: 0.6, relativeHeight: 1.0),
                LayoutPanel(index: 1, content: .waveform, relativeWidth: 0.4, relativeHeight: 0.5),
                LayoutPanel(index: 2, content: .vectorscope, relativeWidth: 0.4, relativeHeight: 0.5)
            ]

        case .tripleTop:
            return [
                LayoutPanel(index: 0, content: .video, relativeWidth: 1.0, relativeHeight: 0.6),
                LayoutPanel(index: 1, content: .waveform, relativeWidth: 0.5, relativeHeight: 0.4),
                LayoutPanel(index: 2, content: .vectorscope, relativeWidth: 0.5, relativeHeight: 0.4)
            ]

        case .grid3x1:
            let w: CGFloat = 1.0 / 3.0
            return [
                LayoutPanel(index: 0, content: .video, relativeWidth: w, relativeHeight: 1.0),
                LayoutPanel(index: 1, content: .waveform, relativeWidth: w, relativeHeight: 1.0),
                LayoutPanel(index: 2, content: .vectorscope, relativeWidth: w, relativeHeight: 1.0)
            ]

        case .grid1x3:
            let h: CGFloat = 1.0 / 3.0
            return [
                LayoutPanel(index: 0, content: .video, relativeWidth: 1.0, relativeHeight: h),
                LayoutPanel(index: 1, content: .waveform, relativeWidth: 1.0, relativeHeight: h),
                LayoutPanel(index: 2, content: .vectorscope, relativeWidth: 1.0, relativeHeight: h)
            ]

        case .sixPack:
            let w: CGFloat = 1.0 / 3.0
            let h: CGFloat = 0.5
            return (0..<6).map { i in
                LayoutPanel(index: i, content: defaultContents[i], relativeWidth: w, relativeHeight: h)
            }
        }
    }

    // MARK: - Persistence

    /// Saves the current layout state to UserDefaults.
    public func saveToDefaults() {
        UserDefaults.standard.set(currentLayout.rawValue, forKey: DefaultsKey.layoutMode)
        if let data = try? JSONEncoder().encode(panels) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.panels)
        }
        UserDefaults.standard.set(showScopeLabels, forKey: DefaultsKey.showLabels)
        UserDefaults.standard.set(showScopeControls, forKey: DefaultsKey.showControls)
        UserDefaults.standard.set(Double(panelSpacing), forKey: DefaultsKey.spacing)
        if let data = try? JSONEncoder().encode(splitRatios) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.splitRatios)
        }
    }

    /// Restores layout state from UserDefaults. Called during init.
    private func restoreFromDefaults() {
        if let rawMode = UserDefaults.standard.string(forKey: DefaultsKey.layoutMode),
           let mode = LayoutMode(rawValue: rawMode) {
            currentLayout = mode
        }

        if let data = UserDefaults.standard.data(forKey: DefaultsKey.panels),
           let decoded = try? JSONDecoder().decode([LayoutPanel].self, from: data),
           !decoded.isEmpty {
            panels = decoded
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.showLabels) != nil {
            showScopeLabels = UserDefaults.standard.bool(forKey: DefaultsKey.showLabels)
        }

        if UserDefaults.standard.object(forKey: DefaultsKey.showControls) != nil {
            showScopeControls = UserDefaults.standard.bool(forKey: DefaultsKey.showControls)
        }

        let spacingVal = UserDefaults.standard.double(forKey: DefaultsKey.spacing)
        if spacingVal > 0 {
            panelSpacing = CGFloat(spacingVal)
        }

        if let data = UserDefaults.standard.data(forKey: DefaultsKey.splitRatios),
           let decoded = try? JSONDecoder().decode([String: CGFloat].self, from: data) {
            splitRatios = decoded
        }
    }
}

// MARK: - Resize drag handle

/// Draggable handle for resizing panels. Shows a highlight on hover and changes cursor.
private struct ResizeDragHandle: View {
    let axis: HandleAxis
    let onDrag: (CGFloat) -> Void

    @State private var isHovered = false

    enum HandleAxis {
        case horizontal
        case vertical
    }

    var body: some View {
        Rectangle()
            .fill(isHovered ? AJATheme.accent.opacity(0.5) : Color.white.opacity(0.08))
            .frame(
                width: axis == .horizontal ? 6 : nil,
                height: axis == .vertical ? 6 : nil
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        onDrag(delta)
                    }
            )
    }
}

// MARK: - Flexible layout view (UI-020)

/// Builds the panel grid for the current layout mode using GeometryReader. Supports drag-to-swap
/// between any panels, resizable drag handles, and animated layout transitions.
public struct FlexibleLayoutView: View {
    @ObservedObject var layoutManager: FlexibleLayoutManager
    let panelBuilder: (Int, Binding<QuadrantContent>) -> AnyView
    var onEnterFullScreen: ((Int) -> Void)?

    public init(
        layoutManager: FlexibleLayoutManager,
        panelBuilder: @escaping (Int, Binding<QuadrantContent>) -> AnyView,
        onEnterFullScreen: ((Int) -> Void)? = nil
    ) {
        self.layoutManager = layoutManager
        self.panelBuilder = panelBuilder
        self.onEnterFullScreen = onEnterFullScreen
    }

    public var body: some View {
        GeometryReader { geometry in
            layoutContent(in: geometry.size)
        }
        .animation(.easeInOut(duration: 0.25), value: layoutManager.currentLayout)
        .animation(.easeInOut(duration: 0.25), value: layoutManager.panels.count)
    }

    // MARK: Layout dispatch

    @ViewBuilder
    private func layoutContent(in size: CGSize) -> some View {
        let spacing = layoutManager.panelSpacing

        switch layoutManager.currentLayout {
        case .single:
            singleLayout(in: size)

        case .sideBySide:
            sideBySideLayout(in: size, spacing: spacing)

        case .stacked:
            stackedLayout(in: size, spacing: spacing)

        case .quad:
            quadLayout(in: size, spacing: spacing)

        case .tripleLeft:
            tripleLeftLayout(in: size, spacing: spacing)

        case .tripleTop:
            tripleTopLayout(in: size, spacing: spacing)

        case .grid3x1:
            grid3x1Layout(in: size, spacing: spacing)

        case .grid1x3:
            grid1x3Layout(in: size, spacing: spacing)

        case .sixPack:
            sixPackLayout(in: size, spacing: spacing)
        }
    }

    // MARK: - Individual layout builders

    private func singleLayout(in size: CGSize) -> some View {
        panelView(at: 0)
            .frame(width: size.width, height: size.height)
    }

    private func sideBySideLayout(in size: CGSize, spacing: CGFloat) -> some View {
        let handleW: CGFloat = 6
        let ratio = layoutManager.splitRatio(for: "sideBySide.h", default: 0.5)
        let leftW = (size.width - handleW) * ratio
        let rightW = size.width - handleW - leftW

        return HStack(spacing: 0) {
            panelView(at: 0)
                .frame(width: leftW, height: size.height)
            ResizeDragHandle(axis: .horizontal) { delta in
                layoutManager.setSplitRatio(for: "sideBySide.h", value: ratio + delta / size.width)
            }
            panelView(at: 1)
                .frame(width: rightW, height: size.height)
        }
        .frame(width: size.width, height: size.height)
    }

    private func stackedLayout(in size: CGSize, spacing: CGFloat) -> some View {
        let handleH: CGFloat = 6
        let ratio = layoutManager.splitRatio(for: "stacked.v", default: 0.5)
        let topH = (size.height - handleH) * ratio
        let bottomH = size.height - handleH - topH

        return VStack(spacing: 0) {
            panelView(at: 0)
                .frame(width: size.width, height: topH)
            ResizeDragHandle(axis: .vertical) { delta in
                layoutManager.setSplitRatio(for: "stacked.v", value: ratio + delta / size.height)
            }
            panelView(at: 1)
                .frame(width: size.width, height: bottomH)
        }
        .frame(width: size.width, height: size.height)
    }

    private func quadLayout(in size: CGSize, spacing: CGFloat) -> some View {
        let handleSize: CGFloat = 6
        let hRatio = layoutManager.splitRatio(for: "quad.h", default: 0.5)
        let vRatio = layoutManager.splitRatio(for: "quad.v", default: 0.5)
        let leftW = (size.width - handleSize) * hRatio
        let rightW = size.width - handleSize - leftW
        let topH = (size.height - handleSize) * vRatio
        let bottomH = size.height - handleSize - topH

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                panelView(at: 0)
                    .frame(width: leftW, height: topH)
                ResizeDragHandle(axis: .horizontal) { delta in
                    layoutManager.setSplitRatio(for: "quad.h", value: hRatio + delta / size.width)
                }
                panelView(at: 1)
                    .frame(width: rightW, height: topH)
            }
            ResizeDragHandle(axis: .vertical) { delta in
                layoutManager.setSplitRatio(for: "quad.v", value: vRatio + delta / size.height)
            }
            HStack(spacing: 0) {
                panelView(at: 2)
                    .frame(width: leftW, height: bottomH)
                ResizeDragHandle(axis: .horizontal) { delta in
                    layoutManager.setSplitRatio(for: "quad.h", value: hRatio + delta / size.width)
                }
                panelView(at: 3)
                    .frame(width: rightW, height: bottomH)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func tripleLeftLayout(in size: CGSize, spacing: CGFloat) -> some View {
        let handleSize: CGFloat = 6
        let hRatio = layoutManager.splitRatio(for: "tripleLeft.h", default: 0.6)
        let vRatio = layoutManager.splitRatio(for: "tripleLeft.v", default: 0.5)
        let leftW = (size.width - handleSize) * hRatio
        let rightW = size.width - handleSize - leftW
        let topH = (size.height - handleSize) * vRatio
        let bottomH = size.height - handleSize - topH

        return HStack(spacing: 0) {
            panelView(at: 0)
                .frame(width: leftW, height: size.height)
            ResizeDragHandle(axis: .horizontal) { delta in
                layoutManager.setSplitRatio(for: "tripleLeft.h", value: hRatio + delta / size.width)
            }
            VStack(spacing: 0) {
                panelView(at: 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: topH)
                ResizeDragHandle(axis: .vertical) { delta in
                    layoutManager.setSplitRatio(for: "tripleLeft.v", value: vRatio + delta / size.height)
                }
                panelView(at: 2)
                    .frame(maxWidth: .infinity)
                    .frame(height: bottomH)
            }
            .frame(width: rightW, height: size.height)
        }
        .frame(width: size.width, height: size.height)
    }

    private func tripleTopLayout(in size: CGSize, spacing: CGFloat) -> some View {
        let handleSize: CGFloat = 6
        let vRatio = layoutManager.splitRatio(for: "tripleTop.v", default: 0.6)
        let hRatio = layoutManager.splitRatio(for: "tripleTop.h", default: 0.5)
        let topH = (size.height - handleSize) * vRatio
        let bottomH = size.height - handleSize - topH
        let leftW = (size.width - handleSize) * hRatio
        let rightW = size.width - handleSize - leftW

        return VStack(spacing: 0) {
            panelView(at: 0)
                .frame(width: size.width, height: topH)
            ResizeDragHandle(axis: .vertical) { delta in
                layoutManager.setSplitRatio(for: "tripleTop.v", value: vRatio + delta / size.height)
            }
            HStack(spacing: 0) {
                panelView(at: 1)
                    .frame(maxHeight: .infinity)
                    .frame(width: leftW)
                ResizeDragHandle(axis: .horizontal) { delta in
                    layoutManager.setSplitRatio(for: "tripleTop.h", value: hRatio + delta / size.width)
                }
                panelView(at: 2)
                    .frame(maxHeight: .infinity)
                    .frame(width: rightW)
            }
            .frame(width: size.width, height: bottomH)
        }
        .frame(width: size.width, height: size.height)
    }

    private func grid3x1Layout(in size: CGSize, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            panelView(at: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            panelView(at: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            panelView(at: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
    }

    private func grid1x3Layout(in size: CGSize, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            panelView(at: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            panelView(at: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            panelView(at: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
    }

    private func sixPackLayout(in size: CGSize, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                panelView(at: 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                panelView(at: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                panelView(at: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: spacing) {
                panelView(at: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                panelView(at: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                panelView(at: 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Panel wrapper

    /// Wraps a single panel with header, drag-to-swap, and context menu support.
    @ViewBuilder
    private func panelView(at index: Int) -> some View {
        let binding = layoutManager.panelContent(at: index)
        let panelExists = index >= 0 && index < layoutManager.panels.count

        VStack(spacing: 0) {
            // Panel header: scope label + fullscreen button
            if layoutManager.showScopeLabels || onEnterFullScreen != nil {
                panelHeader(at: index, content: binding)
            }

            // Panel content provided by caller
            if panelExists {
                panelBuilder(index, binding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholderView(at: index)
            }
        }
        .background(AJATheme.panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(AJATheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            panelContextMenu(at: index, content: binding)
        }
        .draggable(PanelDragItem(panelIndex: index))
        .dropDestination(for: PanelDragItem.self) { items, _ in
            guard let item = items.first, item.panelIndex != index else { return false }
            withAnimation(.easeInOut(duration: 0.2)) {
                layoutManager.swapPanels(source: item.panelIndex, target: index)
            }
            return true
        }
    }

    /// Compact header bar with scope type label and fullscreen button.
    private func panelHeader(at index: Int, content: Binding<QuadrantContent>) -> some View {
        HStack(spacing: 4) {
            if layoutManager.showScopeLabels {
                Text(content.wrappedValue.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AJATheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let onFullScreen = onEnterFullScreen {
                Button {
                    onFullScreen(index)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(AJATheme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Full screen")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }

    /// Context menu for changing the scope type assigned to a panel.
    @ViewBuilder
    private func panelContextMenu(at index: Int, content: Binding<QuadrantContent>) -> some View {
        Section("Switch to") {
            ForEach(QuadrantContent.allCases, id: \.rawValue) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        content.wrappedValue = item
                    }
                } label: {
                    HStack {
                        Text(item.displayName)
                        if content.wrappedValue == item {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        if onEnterFullScreen != nil {
            Divider()
            Button("Enter Full Screen") {
                onEnterFullScreen?(index)
            }
        }
    }

    /// Placeholder shown when a panel index is out of range.
    private func placeholderView(at index: Int) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.dashed")
                .font(.title2)
                .foregroundStyle(AJATheme.tertiaryText)
            Text("Panel \(index + 1)")
                .font(.caption2)
                .foregroundStyle(AJATheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AJATheme.panelBackground)
    }
}

// MARK: - Layout toolbar view (UI-020)

/// Compact toolbar showing layout mode selection buttons. Designed to fit inside a toolbar
/// or sidebar, with icon-only buttons that highlight the currently active layout.
public struct LayoutToolbarView: View {
    @ObservedObject var layoutManager: FlexibleLayoutManager

    public init(layoutManager: FlexibleLayoutManager) {
        self.layoutManager = layoutManager
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(LayoutMode.allCases, id: \.rawValue) { mode in
                layoutButton(for: mode)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(AJATheme.panelBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func layoutButton(for mode: LayoutMode) -> some View {
        let isSelected = layoutManager.currentLayout == mode

        return Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                layoutManager.applyLayout(mode)
            }
        } label: {
            Image(systemName: mode.icon)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AJATheme.accent : AJATheme.secondaryText)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? AJATheme.accent.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(mode.displayName)
    }
}
