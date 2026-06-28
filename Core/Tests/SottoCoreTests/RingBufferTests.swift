import XCTest
@testable import SottoCore

final class RingBufferTests: XCTestCase {

    func testWriteReadFIFO() {
        let buffer = RingBuffer<Int>(capacity: 4)
        buffer.write(1)
        buffer.write(2)
        buffer.write(3)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.read(), 1)
        XCTAssertEqual(buffer.read(), 2)
        XCTAssertEqual(buffer.read(), 3)
        XCTAssertNil(buffer.read())
        XCTAssertEqual(buffer.count, 0)
    }

    func testOverflowDropsOldest() {
        let buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...5 { buffer.write(value) }   // 1,2 вытеснены
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.dropped, 2)
        XCTAssertEqual(buffer.read(), 3)
        XCTAssertEqual(buffer.read(), 4)
        XCTAssertEqual(buffer.read(), 5)
        XCTAssertNil(buffer.read())
    }

    func testInterleavedWriteRead() {
        let buffer = RingBuffer<String>(capacity: 2)
        buffer.write("a")
        XCTAssertEqual(buffer.read(), "a")
        buffer.write("b")
        buffer.write("c")
        XCTAssertEqual(buffer.read(), "b")
        XCTAssertEqual(buffer.read(), "c")
        XCTAssertEqual(buffer.dropped, 0)
    }
}
