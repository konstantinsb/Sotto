import XCTest
@testable import SottoCore

final class DeviceCapabilitiesTests: XCTestCase {

    func testReadsRealMemory() {
        let device = DeviceCapabilities.current()
        XCTAssertGreaterThan(device.totalRAMBytes, 0)
        XCTAssertFalse(device.chipName.isEmpty)
    }

    func testTierBoundaries() {
        XCTAssertEqual(tier(forGB: 8), .fast)
        XCTAssertEqual(tier(forGB: 16), .balanced)
        XCTAssertEqual(tier(forGB: 24), .balanced)
        XCTAssertEqual(tier(forGB: 32), .quality)
        XCTAssertEqual(tier(forGB: 64), .quality)
    }

    private func tier(forGB gb: UInt64) -> DeviceCapabilities.QualityTier {
        DeviceCapabilities(
            chipName: "Test",
            totalRAMBytes: gb * 1_073_741_824,
            performanceCores: 4
        ).recommendedTier
    }
}
