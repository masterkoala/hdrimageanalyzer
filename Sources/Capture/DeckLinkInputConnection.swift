import Foundation
import DeckLinkBridge

/// Video input connection type (BMDVideoConnection). Matches CapturePreview sample: SDI, HDMI, etc.
/// Set via DeckLinkBridgeSetCurrentInputConnection before enumerating modes or starting capture.
public enum DeckLinkVideoConnection: UInt64, CaseIterable, Sendable {
    case unspecified = 0
    case sdi = 1
    case hdmi = 2
    case opticalSDI = 4
    case component = 8
    case composite = 16
    case sVideo = 32
    case ethernet = 64
    case opticalEthernet = 128
    case `internal` = 256

    public var displayName: String {
        switch self {
        case .unspecified: return "Unspecified"
        case .sdi: return "SDI"
        case .hdmi: return "HDMI"
        case .opticalSDI: return "Optical SDI"
        case .component: return "Component"
        case .composite: return "Composite"
        case .sVideo: return "S-Video"
        case .ethernet: return "Ethernet"
        case .opticalEthernet: return "Optical Ethernet"
        case .internal: return "Internal"
        }
    }

    public static func from(rawValue value: UInt64) -> DeckLinkVideoConnection? {
        DeckLinkVideoConnection(rawValue: value)
    }

    /// All known connection types in UI order (excluding unspecified).
    public static var pickerCases: [DeckLinkVideoConnection] {
        [.sdi, .hdmi, .opticalSDI, .component, .composite, .sVideo, .ethernet, .opticalEthernet, .internal]
    }
}

/// Returns supported input connections for the device (bitmask from bridge). Only connections present in the bitmask should be shown in the picker.
public func DeckLinkGetSupportedInputConnections(deviceIndex: Int) -> [DeckLinkVideoConnection] {
    let mask = DeckLinkBridgeGetSupportedInputConnections(Int32(deviceIndex))
    if mask < 0 { return [] }
    return DeckLinkVideoConnection.pickerCases.filter { (mask & Int64($0.rawValue)) != 0 }
}

/// Returns current input connection for the device (0 if not set).
public func DeckLinkGetCurrentInputConnection(deviceIndex: Int) -> UInt64 {
    let v = DeckLinkBridgeGetCurrentInputConnection(Int32(deviceIndex))
    return v < 0 ? 0 : UInt64(v)
}

/// Sets the device's input connection. Call before refreshing display modes or starting capture (CapturePreview sample: newConnectionSelected).
public func DeckLinkSetCurrentInputConnection(deviceIndex: Int, connection: UInt64) -> Bool {
    DeckLinkBridgeSetCurrentInputConnection(Int32(deviceIndex), Int64(connection)) == 0
}

/// Returns true if the device supports input format detection (Apply detected video mode).
public func DeckLinkDeviceSupportsInputFormatDetection(deviceIndex: Int) -> Bool {
    DeckLinkBridgeDeviceSupportsInputFormatDetection(Int32(deviceIndex)) == 1
}
