import Foundation
import Logging

/// Wrapper for a single DeckLink device (real SDK via bridge).
public final class DeckLinkDevice {
    public let info: DeckLinkDeviceInfo

    public init(info: DeckLinkDeviceInfo) {
        self.info = info
    }

    /// Supported video display modes (DL-003).
    public func displayModes() -> [DeckLinkDisplayMode] {
        DeckLinkGetDisplayModes(deviceIndex: info.index)
    }
}
