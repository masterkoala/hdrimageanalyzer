import Foundation

/// Frame-accurate timecode context for QC event logging (QC-004, DL-008).
/// When set from the capture pipeline (e.g. DL-008 timecode callback), any QC event
/// logged without an explicit timecode will use this value, giving frame-accurate timecoded logs.
public enum TimecodedQCContext {
    private static let lock = NSLock()
    private static var current: String?

    /// Set the current frame timecode (e.g. from DL-008 RP188/VITC). Call when timecode is available for the frame being processed.
    public static func setCurrentFrameTimecode(_ timecode: String?) {
        lock.lock()
        current = (timecode?.isEmpty == true) ? nil : timecode
        lock.unlock()
    }

    /// Get the current frame timecode, if any. Used by HDRLogger.logQC to fill in missing timecode on events.
    public static func currentFrameTimecode() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Clear the current frame timecode (e.g. when stopping capture). Optional; next set overwrites anyway.
    public static func clearCurrentFrameTimecode() {
        setCurrentFrameTimecode(nil)
    }
}
