import XCTest
@testable import Common

final class CommonTests: XCTestCase {
    func testRingBuffer() {
        let rb = RingBuffer<Int>(capacity: 3)
        XCTAssertTrue(rb.isEmpty)
        XCTAssertTrue(rb.push(1))
        XCTAssertTrue(rb.push(2))
        XCTAssertEqual(rb.pop(), 1)
        XCTAssertEqual(rb.pop(), 2)
        XCTAssertNil(rb.pop())
    }
}
