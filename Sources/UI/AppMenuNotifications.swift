import Foundation

/// Notification names for menu bar actions (UI-005). Post from App commands; observe in MainView/CapturePreviewState to perform.
public enum AppMenuNotifications {
    /// Take screenshot from display texture and save to file (user is prompted).
    public static let takeScreenshot = Notification.Name("HDRApp.TakeScreenshot")
    /// Take screenshot from scope output and save to file.
    public static let takeScopeScreenshot = Notification.Name("HDRApp.TakeScopeScreenshot")
    /// Copy current display screenshot to pasteboard.
    public static let copyScreenshotToPasteboard = Notification.Name("HDRApp.CopyScreenshotToPasteboard")
    /// Open export flow: save display screenshot or QC report (UI-006).
    public static let export = Notification.Name("HDRApp.Export")
    /// Open presets UI (placeholder: log or future presets sheet).
    public static let openPresets = Notification.Name("HDRApp.OpenPresets")
    /// Open device picker (UI-006: wired to Input > Device).
    public static let openDevicePicker = Notification.Name("HDRApp.OpenDevicePicker")
    /// Open format picker (UI-006: wired to Input > Format).
    public static let openFormatPicker = Notification.Name("HDRApp.OpenFormatPicker")
    /// Open scope type selector (UI-006: wired to Analysis > Scope Type).
    public static let openScopeType = Notification.Name("HDRApp.OpenScopeType")
    /// Open colorspace options (UI-006: wired to Analysis > Colorspace).
    public static let openColorspace = Notification.Name("HDRApp.OpenColorspace")
    /// Open display options (UI-006: wired to Display).
    public static let openDisplayOptions = Notification.Name("HDRApp.OpenDisplayOptions")
    /// QC-009: Start timed screenshot capture (default: every 5s, Documents/HDRAnalyzerScreenshots).
    public static let startTimedScreenshot = Notification.Name("HDRApp.StartTimedScreenshot")
    /// QC-009: Stop timed screenshot capture.
    public static let stopTimedScreenshot = Notification.Name("HDRApp.StopTimedScreenshot")
    /// UI-013: Open scopes window (typically on second display).
    public static let showScopesOnSecondDisplay = Notification.Name("HDRApp.ShowScopesOnSecondDisplay")
    /// INT-010: Open Help window (User Guide).
    public static let openHelp = Notification.Name("HDRApp.OpenHelp")
    /// View > Layout: open quadrant layout presets sheet.
    public static let viewLayout = Notification.Name("HDRApp.ViewLayout")
    /// View > Zoom In: increase main content zoom.
    public static let viewZoomIn = Notification.Name("HDRApp.ViewZoomIn")
    /// View > Zoom Out: decrease main content zoom.
    public static let viewZoomOut = Notification.Name("HDRApp.ViewZoomOut")
    /// View > Actual Size: reset main content zoom to 1.0.
    public static let viewActualSize = Notification.Name("HDRApp.ViewActualSize")
}
