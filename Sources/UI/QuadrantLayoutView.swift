import SwiftUI

// MARK: - Quadrant placeholder

/// Placeholder for a quadrant that will later host a scope or video preview.
public struct QuadrantPlaceholderView: View {
    let label: String
    let quadrantIndex: Int

    public init(label: String = "Scope / Video", quadrantIndex: Int = 0) {
        self.label = label
        self.quadrantIndex = quadrantIndex
    }

    public var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(AJATheme.secondaryText)
            Text("Quadrant \(quadrantIndex)")
                .font(.caption2)
                .foregroundStyle(AJATheme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AJATheme.panelBackground)
    }
}

// MARK: - Quadrant container

/// Wraps quadrant content with a consistent border, optional title, and optional full-screen button (UI-004).
public struct QuadrantContainerView<Content: View>: View {
    let title: String?
    var onEnterFullScreen: (() -> Void)?
    let content: Content

    public init(title: String? = nil, onEnterFullScreen: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.onEnterFullScreen = onEnterFullScreen
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if title != nil || onEnterFullScreen != nil {
                HStack {
                    if let title = title {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(AJATheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    if let onEnterFullScreen = onEnterFullScreen {
                        Button(action: onEnterFullScreen) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption)
                                .symbolVariant(.square)
                        }
                        .buttonStyle(.plain)
                        .help("Full screen")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AJATheme.panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(AJATheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
