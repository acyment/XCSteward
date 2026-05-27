// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import XCTest
@testable import XCStewardKit

final class ResultClassPolicyTests: XCTestCase {
    func testTerminalStateMapping() {
        let policy = ResultClassPolicy()

        XCTAssertEqual(policy.terminalState(for: .success), .succeeded)
        XCTAssertEqual(policy.terminalState(for: .canceled), .canceled)
        XCTAssertEqual(policy.terminalState(for: .buildFailure), .failed)
        XCTAssertEqual(policy.terminalState(for: .buildTimeout), .failed)
        XCTAssertEqual(policy.terminalState(for: .unsupportedDestination), .failed)
        XCTAssertEqual(policy.terminalState(for: .runnerBootstrapFailure), .failed)
        XCTAssertEqual(policy.terminalState(for: .artifactFailure), .failed)
        XCTAssertEqual(policy.terminalState(for: .testTimeout), .failed)
        XCTAssertEqual(policy.terminalState(for: .testFailure), .failed)
        XCTAssertEqual(policy.terminalState(for: .internalError), .failed)
    }

    func testSummaryLinesAreStable() {
        let policy = ResultClassPolicy()

        XCTAssertEqual(policy.summaryLine(for: .success), "Tests succeeded")
        XCTAssertEqual(policy.summaryLine(for: .buildFailure), "Build failed")
        XCTAssertEqual(policy.summaryLine(for: .buildTimeout), "Build timed out")
        XCTAssertEqual(policy.summaryLine(for: .unsupportedDestination), "Destination is unsupported")
        XCTAssertEqual(policy.summaryLine(for: .runnerBootstrapFailure), "Runner failed before tests executed")
        XCTAssertEqual(policy.summaryLine(for: .artifactFailure), "Artifacts were missing or invalid")
        XCTAssertEqual(policy.summaryLine(for: .testTimeout), "Tests timed out")
        XCTAssertEqual(policy.summaryLine(for: .testFailure), "Tests failed")
        XCTAssertEqual(policy.summaryLine(for: .canceled), "Canceled")
        XCTAssertEqual(policy.summaryLine(for: .internalError), "Internal error")
    }

    func testJUnitErrorMessagesOnlyCoverInfrastructureStyleRunFailures() {
        let policy = ResultClassPolicy()

        XCTAssertNil(policy.junitErrorMessage(for: .success))
        XCTAssertNil(policy.junitErrorMessage(for: .testFailure))
        XCTAssertEqual(policy.junitErrorMessage(for: .buildFailure), "Build failed")
        XCTAssertEqual(policy.junitErrorMessage(for: .buildTimeout), "Build timed out")
        XCTAssertEqual(policy.junitErrorMessage(for: .unsupportedDestination), "Destination is unsupported")
        XCTAssertEqual(policy.junitErrorMessage(for: .runnerBootstrapFailure), "Runner failed before tests executed")
        XCTAssertEqual(policy.junitErrorMessage(for: .artifactFailure), "Artifacts were missing or invalid")
        XCTAssertEqual(policy.junitErrorMessage(for: .testTimeout), "Tests timed out")
        XCTAssertEqual(policy.junitErrorMessage(for: .canceled), "Canceled")
        XCTAssertEqual(policy.junitErrorMessage(for: .internalError), "Internal error")
    }
}
