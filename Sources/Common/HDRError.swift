import Foundation

/// Shared error types and handling pattern (roadmap F-009). Each module can extend or use these.
public enum HDRError: Error {
    case capture(String)
    case metal(String)
    case scope(String)
    case color(String)
    case audio(String)
    case metadata(String)
    case config(String)
    case network(String)
    case unknown(String)
}
