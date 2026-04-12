import Foundation

/// Per-module log level configuration (roadmap F-004).
public enum LogLevel: String, Codable, CaseIterable {
    case debug
    case info
    case warning
    case error
    case off
}

public struct LogLevelConfig: Codable {
    public var defaultLevel: LogLevel = .info
    public var moduleLevels: [String: LogLevel] = [:]

    public func level(forCategory category: String) -> LogLevel {
        moduleLevels[category] ?? defaultLevel
    }
}
