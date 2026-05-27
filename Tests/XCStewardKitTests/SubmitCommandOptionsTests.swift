// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import XCTest
@testable import XCStewardKit

final class SubmitCommandOptionsTests: XCTestCase {
    func testParseCollectsSubmitOptionsIntoJobRequest() throws {
        let options = try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--wait",
            "--wait-timeout", "45",
            "--json",
            "--progress",
            "--test-plan", "Stable",
            "--simulator-id", "SIM-123",
            "--only-testing", "AppTests/FooTests/testA",
            "--only-testing", "AppTests/FooTests/testB",
            "--skip-testing", "AppTests/SlowTests",
            "--only-test-configuration", "Smoke",
            "--skip-test-configuration", "Flaky",
        ])

        XCTAssertEqual(options.request.project, "demo")
        XCTAssertEqual(options.request.wait, true)
        XCTAssertEqual(options.waitTimeout, 45)
        XCTAssertEqual(options.json, true)
        XCTAssertEqual(options.progress, true)
        XCTAssertEqual(options.request.testPlan, "Stable")
        XCTAssertEqual(options.request.simulatorID, "SIM-123")
        XCTAssertEqual(options.request.onlyTesting, ["AppTests/FooTests/testA", "AppTests/FooTests/testB"])
        XCTAssertEqual(options.request.skipTesting, ["AppTests/SlowTests"])
        XCTAssertEqual(options.request.onlyTestConfigurations, ["Smoke"])
        XCTAssertEqual(options.request.skipTestConfigurations, ["Flaky"])
    }

    func testParseRejectsInvalidWaitTimeout() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--wait-timeout", "0",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --wait-timeout must be at least 1 second")
        }
    }

    func testParseRejectsUnexpectedArguments() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--bogus",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit received unexpected arguments: --bogus")
        }
    }
}
