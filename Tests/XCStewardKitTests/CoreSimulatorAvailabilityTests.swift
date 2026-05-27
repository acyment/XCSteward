// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import XCTest
@testable import XCStewardKit

final class CoreSimulatorAvailabilityTests: XCTestCase {
    func testFlagParsesBooleanNumericAndTextValues() {
        XCTAssertEqual(CoreSimulatorAvailability.flag(true), true)
        XCTAssertEqual(CoreSimulatorAvailability.flag(false), false)
        XCTAssertEqual(CoreSimulatorAvailability.flag(1), true)
        XCTAssertEqual(CoreSimulatorAvailability.flag(0), false)
        XCTAssertEqual(CoreSimulatorAvailability.flag("YES"), true)
        XCTAssertEqual(CoreSimulatorAvailability.flag("NO"), false)
    }

    func testFlagParsesAvailabilityPhrasesConservatively() {
        XCTAssertEqual(CoreSimulatorAvailability.flag("available"), true)
        XCTAssertEqual(CoreSimulatorAvailability.flag("(available)"), true)
        XCTAssertEqual(CoreSimulatorAvailability.flag("unavailable, runtime missing"), false)
        XCTAssertEqual(CoreSimulatorAvailability.flag("not available for this platform"), false)
        XCTAssertEqual(CoreSimulatorAvailability.flag("no available runtime profile"), false)
        XCTAssertNil(CoreSimulatorAvailability.flag("unknown"))
    }

    func testAvailabilityTextPredicates() {
        XCTAssertTrue(CoreSimulatorAvailability.textIndicatesAvailable("(available)"))
        XCTAssertFalse(CoreSimulatorAvailability.textIndicatesAvailable("not available"))
        XCTAssertTrue(CoreSimulatorAvailability.textIndicatesUnavailable("not available"))
        XCTAssertTrue(CoreSimulatorAvailability.textIndicatesUnavailable("unavailable"))
    }
}
