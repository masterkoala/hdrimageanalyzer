import SwiftUI
import AppKit

// MARK: - SC-018 Scope zoom (mouse wheel to zoom, drag to pan, double-click reset)

/// Default zoom limits for most scopes.
public let scopeZoomRange: ClosedRange<CGFloat> = 1.0 ... 10.0

/// Extended zoom range for vectorscope (user needs 10x+ for fine detail inspection).
public let vectorscopeZoomRange: ClosedRange<CGFloat> = 1.0 ... 20.0

/// Sensitivity for scroll delta → zoom change (per wheel tick / trackpad delta).
private let scopeZoomSensitivity: CGFloat = 0.08

/// NSView that captures scroll wheel (zoom), mouse drag (pan), and double-click (reset).
private final class ScopeInteractionView: NSView {
    var onScroll: ((CGFloat, CGPoint) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?

    private var isDragging = false
    private var lastDragPoint: CGPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        if delta != 0 {
            let loc = convert(event.locationInWindow, from: nil)
            onScroll?(delta, loc)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        isDragging = true
        lastDragPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let dx = loc.x - lastDragPoint.x
        let dy = loc.y - lastDragPoint.y
        lastDragPoint = loc
        onDrag?(dx, -dy) // flip Y since NSView Y is up, SwiftUI offset Y is down
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}

/// NSViewRepresentable that captures scroll wheel, drag, and double-click for scope interaction.
private struct ScopeInteractionRepresentable: NSViewRepresentable {
    @Binding var zoom: CGFloat
    @Binding var offset: CGSize
    var maxZoom: CGFloat
    var centerLocked: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(zoom: $zoom, offset: $offset, maxZoom: maxZoom, centerLocked: centerLocked)
    }

    func makeNSView(context: Context) -> ScopeInteractionView {
        let view = ScopeInteractionView()
        view.wantsLayer = true
        view.onScroll = { delta, loc in context.coordinator.applyScroll(delta: delta, at: loc, viewSize: view.bounds.size) }
        view.onDrag = { dx, dy in context.coordinator.applyDrag(dx: dx, dy: dy) }
        view.onDoubleClick = { context.coordinator.resetZoom() }
        return view
    }

    func updateNSView(_ nsView: ScopeInteractionView, context: Context) {
        context.coordinator.zoomBinding = $zoom
        context.coordinator.offsetBinding = $offset
        context.coordinator.maxZoom = maxZoom
        context.coordinator.centerLocked = centerLocked
        nsView.onScroll = { delta, loc in context.coordinator.applyScroll(delta: delta, at: loc, viewSize: nsView.bounds.size) }
        nsView.onDrag = { dx, dy in context.coordinator.applyDrag(dx: dx, dy: dy) }
        nsView.onDoubleClick = { context.coordinator.resetZoom() }
    }

    final class Coordinator {
        var zoomBinding: Binding<CGFloat>
        var offsetBinding: Binding<CGSize>
        var maxZoom: CGFloat
        var centerLocked: Bool

        init(zoom: Binding<CGFloat>, offset: Binding<CGSize>, maxZoom: CGFloat, centerLocked: Bool) {
            zoomBinding = zoom
            offsetBinding = offset
            self.maxZoom = maxZoom
            self.centerLocked = centerLocked
        }

        func applyScroll(delta: CGFloat, at point: CGPoint, viewSize: CGSize) {
            let oldZoom = zoomBinding.wrappedValue
            let newZoom = min(maxZoom, max(1.0, oldZoom + delta * scopeZoomSensitivity))
            guard newZoom != oldZoom else { return }

            if centerLocked {
                // Center-locked zoom: just change scale, offset stays zero (always zoom toward center).
                zoomBinding.wrappedValue = newZoom
                offsetBinding.wrappedValue = .zero
                return
            }

            // Zoom towards cursor: adjust offset so the point under cursor stays fixed.
            let cx = viewSize.width * 0.5
            let cy = viewSize.height * 0.5
            let cursorOffX = point.x - cx
            // NSView Y is flipped relative to SwiftUI
            let cursorOffY = -(point.y - cy)

            let oldOff = offsetBinding.wrappedValue
            let factor = newZoom / oldZoom
            let newOffX = cursorOffX - factor * (cursorOffX - oldOff.width)
            let newOffY = cursorOffY - factor * (cursorOffY - oldOff.height)

            zoomBinding.wrappedValue = newZoom
            offsetBinding.wrappedValue = clampOffset(CGSize(width: newOffX, height: newOffY), zoom: newZoom, viewSize: viewSize)
        }

        func applyDrag(dx: CGFloat, dy: CGFloat) {
            let zoom = zoomBinding.wrappedValue
            guard zoom > 1.0 else { return }
            let old = offsetBinding.wrappedValue
            offsetBinding.wrappedValue = CGSize(width: old.width + dx, height: old.height + dy)
        }

        func resetZoom() {
            zoomBinding.wrappedValue = 1.0
            offsetBinding.wrappedValue = .zero
        }

        private func clampOffset(_ offset: CGSize, zoom: CGFloat, viewSize: CGSize) -> CGSize {
            let maxOffX = max(0, viewSize.width * (zoom - 1) * 0.5)
            let maxOffY = max(0, viewSize.height * (zoom - 1) * 0.5)
            return CGSize(
                width: min(maxOffX, max(-maxOffX, offset.width)),
                height: min(maxOffY, max(-maxOffY, offset.height))
            )
        }
    }
}

/// Modifier that adds mouse-wheel zoom and drag-to-pan to a scope view.
/// Apply to the scope content (ZStack), which gets `.scaleEffect(zoom).offset(offset)`.
public struct ScopeZoomModifier: ViewModifier {
    @Binding public var zoom: CGFloat
    @Binding public var offset: CGSize
    public var maxZoom: CGFloat
    public var centerLocked: Bool

    public init(zoom: Binding<CGFloat>, offset: Binding<CGSize>, maxZoom: CGFloat = 10.0, centerLocked: Bool = false) {
        _zoom = zoom
        _offset = offset
        self.maxZoom = maxZoom
        self.centerLocked = centerLocked
    }

    public func body(content: Content) -> some View {
        content
            .overlay {
                ScopeInteractionRepresentable(zoom: $zoom, offset: $offset, maxZoom: maxZoom, centerLocked: centerLocked)
                    .allowsHitTesting(true)
            }
    }
}

/// Legacy modifier (backwards compat): offset defaults to zero, drag disabled.
public struct ScopeZoomOnlyModifier: ViewModifier {
    @Binding public var zoom: CGFloat
    @State private var offset: CGSize = .zero
    public var maxZoom: CGFloat
    public var centerLocked: Bool

    public init(zoom: Binding<CGFloat>, maxZoom: CGFloat = 10.0, centerLocked: Bool = false) {
        _zoom = zoom
        self.maxZoom = maxZoom
        self.centerLocked = centerLocked
    }

    public func body(content: Content) -> some View {
        content
            .offset(offset)
            .overlay {
                ScopeInteractionRepresentable(zoom: $zoom, offset: $offset, maxZoom: maxZoom, centerLocked: centerLocked)
                    .allowsHitTesting(true)
            }
    }
}

extension View {
    /// Full scope zoom+pan: captures scroll wheel (zoom centered on cursor) and drag (pan when zoomed).
    /// Double-click resets to 1x. Use with `.scaleEffect(zoom).offset(offset)`.
    /// Set `centerLocked: true` for vectorscope-style zoom that always zooms toward center.
    public func scopeZoomOverlay(zoom: Binding<CGFloat>, offset: Binding<CGSize>, maxZoom: CGFloat = 10.0, centerLocked: Bool = false) -> some View {
        modifier(ScopeZoomModifier(zoom: zoom, offset: offset, maxZoom: maxZoom, centerLocked: centerLocked))
    }

    /// Simple scope zoom (legacy): scroll wheel only, no pan. Use with `.scaleEffect(zoom)`.
    public func scopeZoomOverlay(zoom: Binding<CGFloat>, maxZoom: CGFloat = 10.0, centerLocked: Bool = false) -> some View {
        modifier(ScopeZoomOnlyModifier(zoom: zoom, maxZoom: maxZoom, centerLocked: centerLocked))
    }
}
