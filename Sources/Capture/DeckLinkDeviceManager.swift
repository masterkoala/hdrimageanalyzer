import Foundation
import Logging
import DeckLinkBridge
import Common

/// Manages DeckLink device discovery, enumeration, and notification.
/// Wraps the DeckLink bridge C functions for device listing and change notifications (DL-012).
public final class DeckLinkDeviceManager {
    /// Notification posted when DeckLink devices are added or removed.
    public static let deckLinkDeviceListDidChangeNotification = Notification.Name("DeckLinkDeviceListDidChange")

    private let logCategory = "Capture.DeviceManager"

    public init() {
        // Register for device arrival/removal notifications from bridge
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DeckLinkBridgeSetDeviceNotificationCallback({ ctx, added in
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: DeckLinkDeviceManager.deckLinkDeviceListDidChangeNotification,
                    object: nil,
                    userInfo: ["added": added]
                )
            }
        }, ctx)
        DeckLinkBridgeStartDeviceNotifications()
    }

    deinit {
        DeckLinkBridgeStopDeviceNotifications()
    }

    /// Enumerate all available DeckLink devices via the bridge.
    public func enumerateDevices() -> [DeckLinkDeviceInfo] {
        // Refresh from DeckLink iterator
        DeckLinkBridgeRefreshDeviceListFromIterator()
        let count = Int(DeckLinkBridgeDeviceCount())
        guard count > 0 else { return [] }

        var devices: [DeckLinkDeviceInfo] = []
        var nameBuf = [CChar](repeating: 0, count: 256)

        for i in 0..<count {
            let result = DeckLinkBridgeDeviceName(Int32(i), &nameBuf, 256)
            let name: String
            if result == 0 {
                name = String(cString: nameBuf)
            } else {
                name = "DeckLink Device \(i)"
            }
            devices.append(DeckLinkDeviceInfo(index: i, displayName: name))
        }

        HDRLogger.debug(category: logCategory, "Enumerated \(devices.count) DeckLink device(s)")
        return devices
    }

    /// Start DeckLink hot-plug notifications (DL-012). Idempotent — safe to call multiple times.
    /// Called from CapturePreviewState.startDeviceNotifications() and on view appear.
    public func startDeviceNotifications() {
        // Bridge notifications are started in init; this is a safe no-op re-entry point
        // so callers can ensure notifications are active without tracking state.
        DeckLinkBridgeStartDeviceNotifications()
    }

    /// Refresh the internal device list from the DeckLink iterator. Merges devices not reported
    /// via hot-plug callback (e.g. devices already connected at launch). Called when user taps Refresh.
    public func refreshDeviceListFromIterator() {
        DeckLinkBridgeRefreshDeviceListFromIterator()
    }

    /// Check if any DeckLink devices are available.
    public var hasDevices: Bool {
        DeckLinkBridgeRefreshDeviceListFromIterator()
        return DeckLinkBridgeDeviceCount() > 0
    }

    /// Returns a DeckLinkDevice wrapper for a specific index.
    public func device(at index: Int) -> DeckLinkDevice? {
        let devices = enumerateDevices()
        guard index < devices.count else { return nil }
        return DeckLinkDevice(info: devices[index])
    }
}
