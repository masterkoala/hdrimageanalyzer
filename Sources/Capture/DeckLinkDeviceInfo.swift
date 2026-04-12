import Foundation
import Logging

/// Device info from DeckLink bridge (real SDK 15.3).
public struct DeckLinkDeviceInfo {
    public let index: Int
    public let displayName: String

    public init(index: Int, displayName: String) {
        self.index = index
        self.displayName = displayName
    }
}
