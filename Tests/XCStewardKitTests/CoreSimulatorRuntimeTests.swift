// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import XCTest
@testable import XCStewardKit

final class CoreSimulatorRuntimeTests: XCTestCase {
    func testNormalizesRuntimeIdentifiersAndNames() {
        XCTAssertEqual(
            CoreSimulatorRuntime.normalized("com.apple.CoreSimulator.SimRuntime.iOS-18-0"),
            "ios180"
        )
        XCTAssertEqual(CoreSimulatorRuntime.normalized("iOS 18.0"), "ios180")
        XCTAssertEqual(CoreSimulatorRuntime.normalized(" com.apple.CoreSimulator.ios-18-0 "), "ios180")
    }

    func testMatchesCaseVariedRuntimeIdentifiers() {
        XCTAssertTrue(CoreSimulatorRuntime.matches(
            "COM.APPLE.CORESIMULATOR.SIMRUNTIME.IOS-18-0",
            "iOS 18.0"
        ))
        XCTAssertFalse(CoreSimulatorRuntime.matches(
            "com.apple.CoreSimulator.SimRuntime.iOS-17-4",
            "iOS 18.0"
        ))
    }

    func testDetectsIOSRuntimeWithoutMatchingTVOS() {
        XCTAssertTrue(CoreSimulatorRuntime.isIOSRuntime(
            identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            name: nil
        ))
        XCTAssertTrue(CoreSimulatorRuntime.isIOSRuntime(
            identifier: nil,
            name: " iOS 18.0 "
        ))
        XCTAssertFalse(CoreSimulatorRuntime.isIOSRuntime(
            identifier: "com.apple.CoreSimulator.SimRuntime.tvOS-18-0",
            name: "tvOS 18.0"
        ))
    }
}
