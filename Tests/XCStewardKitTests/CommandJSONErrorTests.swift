// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest

final class CommandJSONErrorTests: XCTestCase {
    func testUsageErrorIsJSONWhenJSONWasRequested() throws {
        let result = try runCLI(arguments: ["submit", "--json"])

        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["message"] as? String, "submit requires --project")
    }

    func testSubmitRejectsUnexpectedArgumentsBeforeQueueMutation() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(arguments: [
            "submit",
            "--state-root", stateRoot.path,
            "--project", "demo",
            "--bogus",
            "--json",
        ])

        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["message"] as? String, "submit received unexpected arguments: --bogus")
        let jobEntries = try? FileManager.default.contentsOfDirectory(
            atPath: stateRoot.appendingPathComponent("jobs").path
        )
        XCTAssertEqual(jobEntries ?? [], [])
    }

    func testSubmitRejectsMissingOptionValueBeforeQueueMutation() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(arguments: [
            "submit",
            "--state-root", stateRoot.path,
            "--project", "demo",
            "--simulator-id", "--json",
        ])

        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["message"] as? String, "Option --simulator-id requires a value")
        let jobEntries = try? FileManager.default.contentsOfDirectory(
            atPath: stateRoot.appendingPathComponent("jobs").path
        )
        XCTAssertEqual(jobEntries ?? [], [])
    }

    func testGlobalStateRootRejectsMissingOptionValueBeforeQueueMutation() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", "--json",
                "--project", "demo",
            ],
            environment: ["XCSTEWARD_HOME": stateRoot.path]
        )

        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["message"] as? String, "Option --state-root requires a value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("jobs").path))
    }

    func testStatusRejectsUnexpectedArgumentsBeforeLookup() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(arguments: [
            "status",
            "--state-root", stateRoot.path,
            "missing-job",
            "extra",
            "--json",
        ])

        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["message"] as? String, "status received unexpected arguments: extra")
    }

    func testCommandsRejectUnexpectedArgumentsBeforeLookupOrMutation() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let cases: [(arguments: [String], message: String)] = [
            (
                ["jobs", "--state-root", stateRoot.path, "extra", "--json"],
                "jobs received unexpected arguments: extra"
            ),
            (
                ["artifacts", "--state-root", stateRoot.path, "missing-job", "extra", "--json"],
                "artifacts received unexpected arguments: extra"
            ),
            (
                ["cancel", "--state-root", stateRoot.path, "missing-job", "extra", "--json"],
                "cancel received unexpected arguments: extra"
            ),
            (
                ["cleanup", "--state-root", stateRoot.path, "--dry-run", "--bogus", "--json"],
                "cleanup received unexpected arguments: --bogus"
            ),
            (
                ["doctor", "--state-root", stateRoot.path, "--bogus", "--json"],
                "doctor received unexpected arguments: --bogus"
            ),
        ]

        for testCase in cases {
            let result = try runCLI(arguments: testCase.arguments)

            XCTAssertEqual(result.status, 2, testCase.arguments.joined(separator: " "))
            XCTAssertEqual(result.stdout, "", testCase.arguments.joined(separator: " "))
            let error = try commandError(from: result.stderr)
            XCTAssertEqual(error["code"] as? String, "usage", testCase.arguments.joined(separator: " "))
            XCTAssertEqual(error["message"] as? String, testCase.message, testCase.arguments.joined(separator: " "))
        }
    }

    func testNotFoundErrorIsJSONWhenJSONWasRequested() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(arguments: ["status", "--state-root", stateRoot.path, "missing-job", "--json"])

        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "not_found")
        XCTAssertEqual(error["message"] as? String, "Job missing-job not found")
    }

    func testInvalidProfileErrorIsJSONWhenJSONWasRequested() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try writeText(
            """
            repo_root = "\(repoRoot.path)"
            """,
            to: stateRoot.appendingPathComponent("projects/broken.toml")
        )
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)

        let result = try runCLI(
            arguments: ["doctor", "--state-root", stateRoot.path, "--project", "broken", "--json"],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "invalid_configuration")
        XCTAssertEqual(error["message"] as? String, "Profile broken is missing repo_root or scheme")
    }

    func testCleanupSizeBudgetUsageErrorIsJSONWhenJSONWasRequested() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(arguments: [
            "cleanup",
            "--state-root", stateRoot.path,
            "--max-total-size", "not-a-size",
            "--json",
        ])

        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["message"] as? String, "cleanup --max-total-size must be a non-negative size")
    }

    func testStateRootFileFailureIsStableJSONBeforeQueueMutation() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        try writeText("not a directory", to: stateRoot)

        let result = try runCLI(arguments: [
            "submit",
            "--state-root", stateRoot.path,
            "--project", "demo",
            "--json",
        ])

        XCTAssertEqual(result.status, 5)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "state_root_unavailable")
        XCTAssertTrue((error["message"] as? String)?.contains("Unable to prepare XCSteward state root") == true)
        XCTAssertTrue((error["message"] as? String)?.contains(stateRoot.path) == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("jobs").path))
    }

    func testReadOnlyStateRootFailureIsStableJSONBeforeQueueMutation() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stateRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stateRoot.path)
        }
        if FileManager.default.isWritableFile(atPath: stateRoot.path) {
            throw XCTSkip("Current user can still write to chmod 0555 state root")
        }

        let result = try runCLI(arguments: [
            "submit",
            "--state-root", stateRoot.path,
            "--project", "demo",
            "--json",
        ])

        XCTAssertEqual(result.status, 5)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "state_root_unavailable")
        XCTAssertTrue((error["message"] as? String)?.contains("Unable to prepare XCSteward state root") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("jobs").path))
    }

    func testCorruptStateDatabasePathFailureIsStableJSONBeforeQueueMutation() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let databasePath = stateRoot.appendingPathComponent("state.db")
        try FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)

        let result = try runCLI(arguments: [
            "submit",
            "--state-root", stateRoot.path,
            "--project", "demo",
            "--json",
        ])

        XCTAssertEqual(result.status, 5)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "state_root_unavailable")
        XCTAssertTrue((error["message"] as? String)?.contains("Unable to open XCSteward state database") == true)
        XCTAssertTrue((error["message"] as? String)?.contains(databasePath.path) == true)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: stateRoot.appendingPathComponent("jobs").path).isEmpty) ?? true)
    }
}

private func commandError(from stderr: String) throws -> [String: Any] {
    let envelope = try XCTUnwrap(parseJSON(stderr) as? [String: Any])
    return try XCTUnwrap(envelope["error"] as? [String: Any])
}
