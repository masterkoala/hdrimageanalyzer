import Foundation
import CoreVideo

// MARK: - DeckLink Pixel Format Type Alias (Shared Between Common and Capture)

/// Represents a DeckLink-compatible pixel format.
/// This type is defined in Common so it can be used across modules without circular dependencies.
public typealias DeckLinkPixelFormat = UInt32

extension DeckLinkPixelFormat {
    /// 10-bit YUV 4:2:2 packed (v210) - bmdFormat10BitYUV ('v210')
    public static let v210: DeckLinkPixelFormat = 0x76323130

    /// RGB8 32-bit BGRA - bmdFormat8BitBGRA ('BGRA' FourCC)
    public static let rgb8: DeckLinkPixelFormat = 0x42475241

    /// 12-bit RGB 4:4:4 Little-Endian (R12L), full range 0–4095 - bmdFormat12BitRGBLE
    public static let rgb12BitLE: DeckLinkPixelFormat = 0x5231324C

    /// 12-bit RGB 4:4:4 Big-Endian (R12B), full range 0–4095 - bmdFormat12BitRGB
    public static let rgb12Bit: DeckLinkPixelFormat = 0x52313242

    /// Human-readable name for display
    public var displayName: String {
        switch self {
        case 0x76323130: return "10-bit YUV 4:2:2 (v210)"
        case 0x42475241: return "8-bit RGB (BGRA)"
        case 0x5231324C: return "12-bit RGB LE"
        case 0x52313242: return "12-bit RGB BE"
        default: return "Unknown (\(self))"
        }
    }
}

// MARK: - Forward Type Definitions for CaptureSource Protocol

/// These types are defined in the Capture module. For cross-module compatibility, we define
/// lightweight counterparts here that can be used by Common-dependent code.
/// When used with DeckLinkCaptureSession or OFXResolveInputCapture, the actual types from those modules take precedence.

// Note: The real definitions live in DeckLinkCaptureSession.swift (DeckLinkPixelFormat) and CaptureSource-related files

// MARK: - Capture Signal State

/// Represents the current state of a capture signal
public enum CaptureSignalState: Sendable {
    /// Signal state is unknown (no frames received yet)
    case unknown
    /// Signal is present and stable
    case present
    /// Signal has been lost (frames stopped arriving)
    case lost

    public var displayName: String {
        switch self {
        case .unknown: return "Unknown"
        case .present: return "Present"
        case .lost: return "Lost"
        }
    }
}

// MARK: - Pixel Format Type Alias

/// Common pixel format identifier for capture sources (enum version)
public enum CapturePixelFormat {
    /// 10-bit YUV 4:2:2 packed (v210)
    case v210
    /// RGB8 32-bit BGRA
    case rgb8
    /// 12-bit RGB Little-Endian
    case rgb12LE
    /// 12-bit RGB Big-Endian
    case rgb12BE

    public var displayName: String {
        switch self {
        case .v210: return "10-bit YUV 4:2:2 (v210)"
        case .rgb8: return "8-bit RGB (BGRA)"
        case .rgb12LE: return "12-bit RGB LE"
        case .rgb12BE: return "12-bit RGB BE"
        }
    }

    /// Maps to the DeckLinkPixelFormat raw value
    public var rawValue: DeckLinkPixelFormat {
        switch self {
        case .v210: return 0x76323130
        case .rgb8: return 0x42475241
        case .rgb12LE: return 0x5231324C
        case .rgb12BE: return 0x52313242
        }
    }

    /// Creates a CapturePixelFormat from DeckLink raw value
    public init?(fromDeckLinkRawValue value: DeckLinkPixelFormat) {
        switch value {
        case 0x76323130: self = .v210
        case 0x42475241: self = .rgb8
        case 0x5231324C: self = .rgb12LE
        case 0x52313242: self = .rgb12BE
        default: return nil
        }
    }
}

// MARK: - Video Resolution

/// Represents a video resolution and frame rate combination
public struct VideoResolution {
    public let width: Int
    public let height: Int
    public let frameRate: Double

    public init(width: Int, height: Int, frameRate: Double = 29.97) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }

    public var aspectRatio: Double {
        return Double(width) / Double(height)
    }

    public var description: String {
        "\(width)x\(height) @ \(frameRate)fps"
    }

    /// Common resolution presets
    public static let hd720p30 = VideoResolution(width: 1280, height: 720, frameRate: 29.97)
    public static let hd720p60 = VideoResolution(width: 1280, height: 720, frameRate: 59.94)
    public static let hd1080p24 = VideoResolution(width: 1920, height: 1080, frameRate: 23.976)
    public static let hd1080p30 = VideoResolution(width: 1920, height: 1080, frameRate: 29.97)
    public static let hd1080p60 = VideoResolution(width: 1920, height: 1080, frameRate: 59.94)
    public static let uhd4kp24 = VideoResolution(width: 3840, height: 2160, frameRate: 23.976)
    public static let uhd4kp30 = VideoResolution(width: 3840, height: 2160, frameRate: 29.97)
}

// MARK: - Capture Source Protocol (Protocol Extension)

/// Base protocol for any video capture source. This is a lightweight version that can be used
/// in Common-dependent code without importing the full Capture module.
public protocol CaptureSource {
    /// Whether the source is currently capturing data
    var isCapturing: Bool { get }

    /// Current signal state (present/lost/unknown)
    var currentSignalState: CaptureSignalState { get }

    /// Identifier for this source
    var sourceId: String { get }

    /// Source name for display in UI
    var sourceName: String { get }

    /// Connect to the capture source (hardware or service)
    func connect() -> Bool

    /// Disconnect from the capture source
    func disconnect()

    /// Start capturing frames
    func startCapture() -> Bool

    /// Stop capturing frames
    func stopCapture()
}

// MARK: - Capture Source Extensions

/// Extension to check if a capture source is actively providing signal
public extension CaptureSource {
    var hasSignal: Bool { currentSignalState == .present }
    var canStartCapture: Bool { !isCapturing && currentSignalState != .lost }
}

// MARK: - Callback Type Aliases for Common Module

/// For compatibility with DeckLinkCaptureSession callbacks, these aliases are defined in Common.
/// When importing the full Capture module, the real types from DeckLinkCaptureSession are used instead.
public typealias OFXFramePixelBufferHandler = (CVPixelBuffer, Int, Int) -> Void
public typealias OFXFormatChangeHandler = (Int, Int, Double) -> Void  // width, height, frameRate
public typealias OFXSignalStateHandler = (CaptureSignalState) -> Void
public typealias OFXTimecodeHandler = (String) -> Void

// MARK: - Capture Source Base Class - Lightweight Version

/// Base class providing common implementation for capture sources.
/// Note: For full DeckLinkPixelFormat support, import the Capture module and use
/// the extended version defined in DeckLinkDeviceManager.swift
open class CaptureSourceBase {
    public let sourceId: String
    public let sourceName: String

    open var isActive = false
    open var signalState: CaptureSignalState = .unknown

    public init(sourceId: String, sourceName: String) {
        self.sourceId = sourceId
        self.sourceName = sourceName
    }

    open var isCapturing: Bool { isActive }
    open var currentSignalState: CaptureSignalState { signalState }

    open func connect() -> Bool {
        return true
    }

    open func disconnect() {
        stopCapture()
        isActive = false
        signalState = .unknown
    }

    /// Lightweight configure that doesn't require DeckLink types
    open func configureWithBasicParams(width: Int, height: Int, frameRate: Double) -> Bool {
        return true
    }

    open func startCapture() -> Bool {
        isActive = true
        signalState = .present
        return true
    }

    open func stopCapture() {
        isActive = false
        signalState = .unknown
    }
}
