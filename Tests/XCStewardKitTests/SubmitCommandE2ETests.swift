// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest

final class SubmitCommandE2ETests: XCTestCase {
    func testRootHelpPrintsUsageWithoutCreatingState() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(
            arguments: [
                "--state-root", stateRoot.path,
                "--help",
            ]
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Usage:"))
        XCTAssertTrue(result.stdout.contains("xcsteward [--state-root <path>] <command> [options]"))
        XCTAssertTrue(result.stdout.contains("submit"))
        XCTAssertEqual(result.stderr, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateRoot.path))
    }

    func testSubmitHelpPrintsCommandUsage() throws {
        let result = try runCLI(arguments: ["submit", "--help"])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("xcsteward [--state-root <path>] submit --project <name> [options]"))
        XCTAssertTrue(result.stdout.contains("--only-testing <identifier>"))
        XCTAssertTrue(result.stdout.contains("--skip-testing <identifier>"))
        XCTAssertTrue(result.stdout.contains("--only-test-configuration <name>"))
        XCTAssertTrue(result.stdout.contains("--skip-test-configuration <name>"))
        XCTAssertTrue(result.stdout.contains("--simulator-id <id>"))
        XCTAssertTrue(result.stdout.contains("--progress"))
        XCTAssertEqual(result.stderr, "")
    }

    func testSubmitWaitSuccessCreatesArtifactsAndStructuredSummary() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        let jobID = try e2e.jobID(from: json)
        let jobDir = e2e.jobDir(jobID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("request.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("artifacts/result.xcresult/summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("artifacts/summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("artifacts/run-metadata.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("artifacts/xcodebuild-help.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("logs/combined.log").path))
        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: jobDir.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        let expectedDerivedData = jobDir.appendingPathComponent("derived-data").path
        let expectedResultBundle = jobDir.appendingPathComponent("artifacts/result.xcresult").path
        XCTAssertEqual(runMetadata["job_id"] as? String, jobID)
        XCTAssertEqual(runMetadata["project"] as? String, "demo")
        XCTAssertEqual(runMetadata["simulator_id"] as? String, "SIM-123")
        XCTAssertEqual((runMetadata["exit_code"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, false)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, false)
        XCTAssertTrue((runMetadata["xcode_version"] as? String)?.contains("Xcode 16.4") == true)
        XCTAssertEqual(runMetadata["xcodebuild_path"] as? String, e2e.fakeTools.env["FAKE_XCODEBUILD_PATH"])
        XCTAssertEqual(runMetadata["derived_data_path"] as? String, expectedDerivedData)
        XCTAssertEqual(runMetadata["result_bundle_path"] as? String, expectedResultBundle)
        XCTAssertEqual(runMetadata["summary_path"] as? String, jobDir.appendingPathComponent("artifacts/summary.json").path)
        XCTAssertEqual(runMetadata["combined_log_path"] as? String, jobDir.appendingPathComponent("logs/combined.log").path)
        XCTAssertEqual(runMetadata["build_log_path"] as? String, jobDir.appendingPathComponent("logs/build.log").path)
        XCTAssertEqual(runMetadata["test_log_path"] as? String, jobDir.appendingPathComponent("logs/test.log").path)
        let commandLogPath = try XCTUnwrap(runMetadata["command_log_path"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: commandLogPath))
        let xcodebuildHelpPath = try XCTUnwrap(runMetadata["xcodebuild_help_path"] as? String)
        let xcodebuildHelp = try String(contentsOfFile: xcodebuildHelpPath)
        XCTAssertTrue(xcodebuildHelp.contains("-parallel-testing-enabled"))
        XCTAssertTrue(xcodebuildHelp.contains("-destination-timeout"))
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        XCTAssertEqual(profileMetadata["scheme"] as? String, "Demo")
        let parallelMetadata = try XCTUnwrap(profileMetadata["parallel"] as? [String: Any])
        XCTAssertEqual(parallelMetadata["mode"] as? String, "xcode-managed")
        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let commandDump = "\(commands)"
        let buildCommand = try XCTUnwrap(
            commands.first { ($0["phase"] as? String) == "build" && ($0["tool"] as? String) == "xcodebuild" },
            commandDump
        )
        XCTAssertEqual((buildCommand["exit_code"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(buildCommand["timed_out"] as? Bool, false)
        let buildArguments = try XCTUnwrap(buildCommand["arguments"] as? [String])
        XCTAssertEqual(argumentValue(after: "-derivedDataPath", in: buildArguments), expectedDerivedData)
        let testCommand = try XCTUnwrap(
            commands.first { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" },
            commandDump
        )
        XCTAssertEqual((testCommand["exit_code"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(testCommand["timed_out"] as? Bool, false)
        let testArguments = try XCTUnwrap(testCommand["arguments"] as? [String])
        let xctestrunPath = try XCTUnwrap(argumentValue(after: "-xctestrun", in: testArguments))
        let resolvedXCTestRunPath = URL(fileURLWithPath: xctestrunPath).resolvingSymlinksInPath().path
        let resolvedDerivedData = URL(fileURLWithPath: expectedDerivedData).resolvingSymlinksInPath().path
        XCTAssertTrue(resolvedXCTestRunPath.hasPrefix(resolvedDerivedData + "/"), xctestrunPath)
        XCTAssertEqual(argumentValue(after: "-resultBundlePath", in: testArguments), expectedResultBundle)
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        XCTAssertEqual(artifacts["derivedData"] as? String, expectedDerivedData)
        let junitPath = try XCTUnwrap(artifacts["junit"] as? String)
        XCTAssertEqual(runMetadata["junit_path"] as? String, junitPath)
        let junit = try String(contentsOfFile: junitPath)
        XCTAssertTrue(junit.contains("<testsuite"))
        XCTAssertTrue(junit.contains("tests=\"3\""))
        XCTAssertTrue(junit.contains("failures=\"0\""))
        XCTAssertTrue(junit.contains("errors=\"0\""))
        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_JOB_ID=\(jobID)"))
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PROJECT=demo"))
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PHASE=build"))
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PHASE=test"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_JOB_ID=\(jobID)"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PROJECT=demo"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_MODE=xcode-managed"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PHASE=test"))
        XCTAssertTrue(toolLog.contains("env TMPDIR=\(jobDir.appendingPathComponent("tmp/test").path)"))
    }

    func testSubmitWaitSuccessParsesModernXCResultToolSummary() throws {
        let e2e = try E2EScenario(scenario: .modernXCResultToolSummary)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        let counts = try XCTUnwrap(json["counts"] as? [String: Any])
        XCTAssertEqual(counts["testsRun"] as? Int, 2)
        XCTAssertEqual(counts["testsFailed"] as? Int, 0)
        XCTAssertEqual(counts["testsSkipped"] as? Int, 0)
    }

    func testSubmitSimulatorOverrideWinsOverProfileDefault() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(
            wait: true,
            extraArguments: ["--simulator-id", "SIM-OVERRIDE"]
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try result.jsonObject()
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-OVERRIDE")
        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("-destination id=SIM-OVERRIDE"))
    }
}

private func argumentValue(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}
