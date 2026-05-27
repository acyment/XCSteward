// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest
@testable import XCStewardKit

final class DoctorCommandTests: XCTestCase {
    func testDoctorHelpDocumentsGlobalFixGate() throws {
        let result = try runCLI(arguments: ["doctor", "--help"])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("--fix-global"))
        XCTAssertTrue(result.stdout.contains("--dangerously-confirm-global-coresimulator-cleanup"))
        XCTAssertTrue(result.stdout.contains("CoreSimulator"))
        XCTAssertTrue(result.stdout.contains("--progress"))
    }

    func testDoctorHumanOutputIncludesWarnDetailsAndManualAction() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: ["XCSTEWARD_DOCTOR_WARN_FREE_PERCENT": "101"]
        )

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("warn"))
        XCTAssertTrue(result.stdout.contains("global.disk_pressure_warning"))
        XCTAssertTrue(result.stdout.contains("Disk pressure"))
        XCTAssertTrue(result.stdout.contains("cleanup --dry-run"))
    }

}

struct DoctorCommandResult {
    var cli: CLIResult
    var json: [String: Any]

    var overallStatus: String? {
        json["overall_status"] as? String
    }

    func check(
        _ id: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]], file: file, line: line)
        return try XCTUnwrap(
            checks.first(where: { ($0["id"] as? String) == id }),
            "Missing doctor check \(id)",
            file: file,
            line: line
        )
    }
}

func runDoctorCommand(
    stateRoot: URL,
    project: String? = nil,
    fix: Bool = false,
    fixGlobal: Bool = false,
    confirmGlobalCleanup: Bool = false,
    environment: [String: String],
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> DoctorCommandResult {
    var arguments = [
        "doctor",
        "--state-root", stateRoot.path,
    ]
    if let project {
        arguments.append(contentsOf: ["--project", project])
    }
    if fix {
        arguments.append("--fix")
    }
    if fixGlobal {
        arguments.append("--fix-global")
    }
    if confirmGlobalCleanup {
        arguments.append("--dangerously-confirm-global-coresimulator-cleanup")
    }
    arguments.append("--json")

    let cli = try runCLI(arguments: arguments, environment: environment)
    let json = try XCTUnwrap(parseJSON(cli.stdout) as? [String: Any], file: file, line: line)
    return DoctorCommandResult(cli: cli, json: json)
}
