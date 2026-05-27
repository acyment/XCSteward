// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import XCTest
@testable import DemoApp

final class DemoAppTests: XCTestCase {
    func testGreetingIsStable() {
        XCTAssertEqual(DemoGreeting.message, "Hello from XCSteward")
    }
}
