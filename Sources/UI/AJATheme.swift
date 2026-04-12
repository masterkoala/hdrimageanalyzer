import SwiftUI

// MARK: - UI-014 Dark mode theme matching AJA aesthetic

/// Broadcast-style dark theme inspired by AJA Video Systems: charcoal backgrounds, muted borders, amber accent. Use for main window, panels, and status bar.
public enum AJATheme {
    /// Main window / canvas background (dark charcoal).
    public static let windowBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    /// Panel and card background (slightly darker).
    public static let panelBackground = Color(red: 0.08, green: 0.08, blue: 0.09)
    /// Elevated surface (e.g. scroll content area).
    public static let elevatedBackground = Color(red: 0.13, green: 0.13, blue: 0.14)
    /// Border for panels and quadrant containers.
    public static let border = Color(red: 0.28, green: 0.28, blue: 0.30)
    /// Active / focused border (brighter).
    public static let activeBorder = Color(red: 0.42, green: 0.42, blue: 0.46)
    /// Subtle divider.
    public static let divider = Color(red: 0.22, green: 0.22, blue: 0.24)
    /// Primary text (high contrast).
    public static let primaryText = Color(red: 0.95, green: 0.95, blue: 0.96)
    /// Secondary / label text.
    public static let secondaryText = Color(red: 0.65, green: 0.65, blue: 0.68)
    /// Tertiary / muted text.
    public static let tertiaryText = Color(red: 0.50, green: 0.50, blue: 0.52)
    /// Accent (AJA-style amber) for highlights and key actions.
    public static let accent = Color(red: 0.90, green: 0.55, blue: 0.20)
    /// Accent dimmed (for hover states, subtle highlights).
    public static let accentDimmed = Color(red: 0.90, green: 0.55, blue: 0.20).opacity(0.3)
    /// Status bar strip at bottom of main window.
    public static let statusBarBackground = Color(red: 0.06, green: 0.06, blue: 0.07)
    /// Toolbar background (between window and panel darkness).
    public static let toolbarBackground = Color(red: 0.09, green: 0.09, blue: 0.10)
    /// Scope background (very dark for maximum contrast).
    public static let scopeBackground = Color(red: 0.04, green: 0.04, blue: 0.05)
    /// Signal present indicator.
    public static let signalGreen = Color(red: 0.20, green: 0.78, blue: 0.35)
    /// Signal lost / error.
    public static let signalRed = Color(red: 0.90, green: 0.25, blue: 0.22)
    /// Warning / caution.
    public static let signalYellow = Color(red: 0.95, green: 0.75, blue: 0.15)

    // MARK: - Animation constants

    /// Standard animation for layout transitions.
    public static let layoutAnimation: Animation = .easeInOut(duration: 0.25)
    /// Quick animation for button states, hover.
    public static let quickAnimation: Animation = .easeOut(duration: 0.12)
    /// Scope fade-in/fade-out.
    public static let scopeFadeAnimation: Animation = .easeInOut(duration: 0.3)

    // MARK: - Spacing constants

    /// Standard panel spacing in grid layouts.
    public static let panelSpacing: CGFloat = 4
    /// Standard padding inside panels.
    public static let panelPadding: CGFloat = 6
    /// Toolbar height.
    public static let toolbarHeight: CGFloat = 32
    /// Status bar height.
    public static let statusBarHeight: CGFloat = 28
}
