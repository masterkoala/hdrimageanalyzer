import Foundation
import Logging

/// Configuration settings for OFX integration
public struct OFXConfiguration {
    /// Enable/disable OFX support
    public var isEnabled: Bool = true

    /// Path to OFX plugins directory
    public var pluginDirectory: String = "/usr/local/lib/ofx"

    /// Default frame rate for simulations
    public var defaultFrameRate: Double = 30.0

    /// Default resolution for simulations
    public var defaultResolution: String = "1920x1080"

    /// Enable hardware acceleration for OFX plugins
    public var useHardwareAcceleration: Bool = true

    /// Maximum number of concurrent simulations
    public var maxConcurrentSimulations: Int = 5

    /// Log level for OFX operations
    public var logLevel: LogLevel = .info

    /// Default constructor
    public init() {}

    /// Load configuration from file
    /// - Parameter path: Path to configuration file
    /// - Returns: Configuration object or nil if failed
    public static func load(from path: String) -> OFXConfiguration? {
        // In a real implementation, this would read from a JSON/YAML config file
        HDRLogger.debug(category: "OFX.Configuration", message: "Loading configuration from \(path)")
        return OFXConfiguration()
    }

    /// Save configuration to file
    /// - Parameter path: Path to save configuration file
    public func save(to path: String) {
        // In a real implementation, this would write to a JSON/YAML config file
        HDRLogger.debug(category: "OFX.Configuration", message: "Saving configuration to \(path)")
    }
}

/// Logging levels for OFX operations
public enum LogLevel: String, CaseIterable {
    case debug = "debug"
    case info = "info"
    case warning = "warning"
    case error = "error"

    public static func fromString(_ string: String) -> LogLevel {
        switch string.lowercased() {
        case "debug": return .debug
        case "warning": return .warning
        case "error": return .error
        default: return .info
        }
    }
}