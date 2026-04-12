import XCTest
@testable import Logging

final class LoggingTests: XCTestCase {
    func testLogger() {
        HDRLogger.info(category: "Test", "Logging test")
    }
}
