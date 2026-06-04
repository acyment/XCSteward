// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest

// Every machine-readable document the CLI emits must carry a top-level
// schema_version == 1. Covers the JSON funnels that need no real Xcode:
// the error envelope (stderr), cleanup, and doctor reports (stdout).
final class ContractSchemaVersionTests: XCTestCase {
    func testErrorEnvelopeCarriesSchemaVersion() throws {
        let result = try runCLI(arguments: ["submit", "--json"])
        XCTAssertEqual(result.status, 2)
        let envelope = try XCTUnwrap(parseJSON(result.stderr) as? [String: Any])
        XCTAssertEqual(envelope["schema_version"] as? Int, 1)
        XCTAssertNotNil(envelope["error"])
    }

    func testCleanupReportCarriesSchemaVersion() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let result = try runCLI(arguments: ["cleanup", "--state-root", stateRoot.path, "--json"])
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let report = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(report["schema_version"] as? Int, 1)
    }

    func testDoctorReportCarriesSchemaVersion() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        let result = try runCLI(
            arguments: ["doctor", "--state-root", stateRoot.path, "--json"],
            environment: fakeTools.env
        )
        // Exit code may be 0 or 20 depending on host checks; we only assert the
        // report shape on stdout.
        let report = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(report["schema_version"] as? Int, 1)
        XCTAssertNotNil(report["overall_status"])
    }
}
