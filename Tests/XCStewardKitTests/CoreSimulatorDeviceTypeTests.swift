import XCTest
@testable import XCStewardKit

final class CoreSimulatorDeviceTypeTests: XCTestCase {
    func testNormalizesDeviceTypeIdentifiersAndNames() {
        XCTAssertEqual(
            CoreSimulatorDeviceType.normalized("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"),
            "iphone17pro"
        )
        XCTAssertEqual(CoreSimulatorDeviceType.normalized("iPhone 17 Pro"), "iphone17pro")
        XCTAssertEqual(CoreSimulatorDeviceType.normalized(" com.apple.CoreSimulator.iPhone-17-Pro "), "iphone17pro")
    }

    func testMatchesCaseVariedDeviceTypeIdentifiers() {
        XCTAssertTrue(CoreSimulatorDeviceType.matches(
            "COM.APPLE.CORESIMULATOR.SIMDEVICETYPE.IPHONE-17-PRO",
            "iPhone 17 Pro"
        ))
        XCTAssertFalse(CoreSimulatorDeviceType.matches(
            "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
            "iPhone 17 Pro"
        ))
    }
}
