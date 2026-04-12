import XCTest
@testable import HDRUI

final class HDRUITests: XCTestCase {
    func testAppConfigCodable() {
        var config = AppConfig.current
        config.defaultColorSpace = .rec2020
        AppConfig.save(config)
        let loaded = AppConfig.current
        XCTAssertEqual(loaded.defaultColorSpace, .rec2020)
    }
}
