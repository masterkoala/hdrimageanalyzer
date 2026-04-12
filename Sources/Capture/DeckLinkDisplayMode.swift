import Foundation
import DeckLinkBridge
import Logging

/// A single display mode supported by a DeckLink device (DL-003). DL-013: 8K/quad-link flags.
public struct DeckLinkDisplayMode: Sendable {
    public let name: String
    public let width: Int
    public let height: Int
    public let frameRate: Double
    /// True when resolution is 8K (e.g. 7680×4320 UHD or 8192×4320 DCI).
    public let is8K: Bool
    /// True when this mode is supported with SDI quad-link (four links for 8K capture).
    public let isQuadLink: Bool

    public init(name: String, width: Int, height: Int, frameRate: Double, is8K: Bool = false, isQuadLink: Bool = false) {
        self.name = name
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.is8K = is8K
        self.isQuadLink = isQuadLink
    }
}

/// 8K resolution thresholds (UHD 7680×4320, DCI 8192×4320). DL-013.
private let k8KMinWidth = 7680
private let k8KMinHeight = 4320

/// Fetch display modes for a device (bridge index). DL-013: includes is8K and isQuadLink.
public func DeckLinkGetDisplayModes(deviceIndex: Int) -> [DeckLinkDisplayMode] {
    let n = DeckLinkBridgeDisplayModeCount(Int32(deviceIndex))
    if n <= 0 {
        HDRLogger.debug(category: "Capture", "Format detection device=\(deviceIndex) modes=0")
        return []
    }
    var list: [DeckLinkDisplayMode] = []
    var nameBuf = [CChar](repeating: 0, count: 256)
    var w: Int32 = 0, h: Int32 = 0
    var fps: Double = 0
    var modeFlags: Int32 = 0
    for i in 0..<Int(n) {
        if DeckLinkBridgeDisplayModeInfo(Int32(deviceIndex), Int32(i), &nameBuf, Int32(nameBuf.count), &w, &h, &fps, &modeFlags) == 0 {
            let width = Int(w), height = Int(h)
            let is8K = width >= k8KMinWidth && height >= k8KMinHeight
            let isQuadLink = modeFlags != 0
            let mode = DeckLinkDisplayMode(
                name: String(cString: nameBuf),
                width: width,
                height: height,
                frameRate: fps,
                is8K: is8K,
                isQuadLink: isQuadLink
            )
            list.append(mode)
            HDRLogger.debug(category: "Capture", "Format device=\(deviceIndex) mode[\(i)]: \(mode.name) \(mode.width)x\(mode.height) @ \(mode.frameRate) fps 8K=\(mode.is8K) quad=\(mode.isQuadLink)")
        }
    }
    HDRLogger.info(category: "Capture", "Format detection device=\(deviceIndex) modes=\(list.count)")
    return list
}

/// Returns true if the device supports quad-link SDI (8K). DL-013.
public func DeckLinkDeviceSupportsQuadLinkSDI(deviceIndex: Int) -> Bool {
    DeckLinkBridgeDeviceSupportsQuadLinkSDI(Int32(deviceIndex)) == 1
}

/// Returns mode index for displayModeId (BMDDisplayMode from format change). -1 if not found. Used to restart capture with detected format.
public func DeckLinkModeIndexForDisplayMode(deviceIndex: Int, displayModeId: UInt32) -> Int {
    let idx = DeckLinkBridgeModeIndexForDisplayMode(Int32(deviceIndex), displayModeId)
    return idx >= 0 ? Int(idx) : -1
}

// MARK: - 8K quad-link frame assembly (stub)

/// Stub for future multi-card 4×4K → 8K frame assembly. The DeckLink SDK does **not** expose four separate sub-frames for a single 8K quad-link device: it delivers **one** 8K frame per `VideoInputFrameArrived`. Use the normal capture path for 8K on a quad-link card. This stub is reserved for a hypothetical setup of four independent 4K devices combined into one 8K image (not implemented).
public func DeckLinkCombineQuadSubFramesInto8KStub() -> Bool {
    false
}
