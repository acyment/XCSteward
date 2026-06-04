// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest
@testable import XCStewardKit

final class ContractExitCodeTests: XCTestCase {
    func testExitCodeForErrorMatchesTable() {
        XCTAssertEqual(exitCode(for: XCStewardError.usage("x")), 2)
        XCTAssertEqual(exitCode(for: XCStewardError.notFound("x")), 3)
        XCTAssertEqual(exitCode(for: XCStewardError.invalidConfiguration("x")), 4)
        XCTAssertEqual(exitCode(for: XCStewardError.stateRootUnavailable("x")), 5)
        XCTAssertEqual(exitCode(for: XCStewardError.canceled("x")), 6)
        XCTAssertEqual(exitCode(for: XCStewardError.commandFailed("x")), 7)
        struct Other: Error {}
        XCTAssertEqual(exitCode(for: Other()), 1)
    }

    func testErrorCodeStringsAreStable() {
        XCTAssertEqual(errorCode(for: XCStewardError.usage("x")), "usage")
        XCTAssertEqual(errorCode(for: XCStewardError.notFound("x")), "not_found")
        XCTAssertEqual(errorCode(for: XCStewardError.invalidConfiguration("x")), "invalid_configuration")
        XCTAssertEqual(errorCode(for: XCStewardError.stateRootUnavailable("x")), "state_root_unavailable")
        XCTAssertEqual(errorCode(for: XCStewardError.commandFailed("x")), "command_failed")
        XCTAssertEqual(errorCode(for: XCStewardError.canceled("x")), "canceled")
        struct Other: Error {}
        XCTAssertEqual(errorCode(for: Other()), "unexpected_error")
    }

    func testExitCodeForJobOutcomeMatchesTable() {
        XCTAssertEqual(exitCode(for: .success, state: .succeeded), 0)
        XCTAssertEqual(exitCode(for: .testFailure, state: .failed), 10)
        XCTAssertEqual(exitCode(for: .buildFailure, state: .failed), 10)
        XCTAssertEqual(exitCode(for: .testTimeout, state: .failed), 11)
        XCTAssertEqual(exitCode(for: .buildTimeout, state: .failed), 11)
        XCTAssertEqual(exitCode(for: .runnerBootstrapFailure, state: .failed), 12)
        XCTAssertEqual(exitCode(for: .artifactFailure, state: .failed), 12)
        XCTAssertEqual(exitCode(for: .canceled, state: .canceled), 13)
        XCTAssertEqual(exitCode(for: .internalError, state: .interrupted), 14)
        XCTAssertEqual(exitCode(for: .unsupportedDestination, state: .failed), 14)
    }

    func testExitCodeForNonTerminalJobIsSuccess() {
        XCTAssertEqual(exitCode(for: nil, state: .queued), 0)
        XCTAssertEqual(exitCode(for: nil, state: .running), 0)
    }

    func testExitCodeForUnclassifiedTerminalJob() {
        XCTAssertEqual(exitCode(for: nil, state: .succeeded), 0)
        XCTAssertEqual(exitCode(for: nil, state: .canceled), 13)
        XCTAssertEqual(exitCode(for: nil, state: .interrupted), 1)
    }

    // Older summary.json (written before schema_version existed) must still
    // decode, defaulting to the current version, and re-encode WITH the field.
    func testJobSummaryDecodesWithoutSchemaVersionAndReencodesWithIt() throws {
        let legacy = """
        {
          "job_id": "j1",
          "project": "demo",
          "state": "succeeded",
          "submitted_at": 1.0,
          "only_testing": [],
          "artifacts": {},
          "summary_line": "ok",
          "metadata": {}
        }
        """
        let summary = try decodeJSON(JobSummary.self, from: Data(legacy.utf8))
        XCTAssertEqual(summary.schemaVersion, xcstewardSchemaVersion)
        XCTAssertEqual(summary.artifacts.schemaVersion, xcstewardSchemaVersion)

        let reencoded = String(decoding: try jsonData(summary), as: UTF8.self)
        XCTAssertTrue(reencoded.contains("\"schema_version\""))
    }
}
