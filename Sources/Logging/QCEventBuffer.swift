import Foundation

/// Thread-safe bounded buffer of QC events for session export (QC-005, QC-006).
/// Appended to by HDRLogger.logQC; snapshot used for CSV/XML export.
public enum QCEventBuffer {
    private static let lock = NSLock()
    private static let maxEvents = 10_000
    private static var events: [QCEvent] = []

    /// Append an event to the session buffer (oldest dropped when over capacity).
    public static func append(_ event: QCEvent) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    /// Snapshot of current session events (oldest first). Safe to call from any thread.
    public static func snapshot() -> [QCEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Clear the session buffer (e.g. new session or after export). Optional.
    public static func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
}
