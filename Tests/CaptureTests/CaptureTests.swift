import XCTest
@testable import Capture

final class CaptureTests: XCTestCase {
    func testDeckLinkDeviceManagerExists() {
        let mgr = DeckLinkDeviceManager()
        XCTAssertNotNil(mgr)
    }

    /// DL-018: enumerateDevices() returns an array (count >= 0).
    func testEnumerateDevicesReturnsArray() {
        let mgr = DeckLinkDeviceManager()
        let devices = mgr.enumerateDevices()
        XCTAssertNotNil(devices)
        XCTAssertGreaterThanOrEqual(devices.count, 0)
    }

    /// DL-018: For device index 0 if any, displayModes() returns array; each mode has non-empty name, width > 0, height > 0, frameRate > 0.
    func testDisplayModesForDeviceZero() {
        let mgr = DeckLinkDeviceManager()
        let devices = mgr.enumerateDevices()
        if devices.isEmpty { return }
        let modes = DeckLinkGetDisplayModes(deviceIndex: 0)
        XCTAssertNotNil(modes)
        XCTAssertGreaterThanOrEqual(modes.count, 0)
        for m in modes {
            XCTAssertFalse(m.name.isEmpty, "mode name should not be empty")
            XCTAssertGreaterThan(m.width, 0, "mode width should be > 0")
            XCTAssertGreaterThan(m.height, 0, "mode height should be > 0")
            XCTAssertGreaterThan(m.frameRate, 0, "mode frameRate should be > 0")
        }
    }

    /// DL-018 (optional): Out-of-range device index returns empty array.
    func testDisplayModesOutOfRangeReturnsEmpty() {
        let modesNeg = DeckLinkGetDisplayModes(deviceIndex: -1)
        XCTAssertTrue(modesNeg.isEmpty)
        let modesLarge = DeckLinkGetDisplayModes(deviceIndex: 99999)
        XCTAssertTrue(modesLarge.isEmpty)
    }
}
