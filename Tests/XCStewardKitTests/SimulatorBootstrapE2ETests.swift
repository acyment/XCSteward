// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest

final class SimulatorBootstrapE2ETests: XCTestCase {
    func testBootStatusFailureProducesTerminalRunnerBootstrapFailureSummary() throws {
        let e2e = try E2EScenario(scenario: .bootStatusFailure)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("before XCTest attached") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("environment failure") == true)
        let jobID = try e2e.jobID(from: json)

        let statusJSON = try e2e.status(jobID)
        XCTAssertEqual(statusJSON["state"] as? String, "failed")
        XCTAssertEqual(statusJSON["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertTrue((statusJSON["summary_line"] as? String)?.contains("before XCTest attached") == true)
        XCTAssertTrue((statusJSON["summary_line"] as? String)?.contains("Waiting on Data Migration") == true)
    }

    func testExecutorRecoversWhenAlreadyBootedSimulatorFailsBootstatus() throws {
        let e2e = try E2EScenario(scenario: .bootedSimulatorNeedsRecovery)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try result.jsonObject()
        XCTAssertEqual(json["result_class"] as? String, "success")
        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertGreaterThanOrEqual(toolLog.components(separatedBy: "xcrun simctl boot SIM-123").count - 1, 2)
        XCTAssertGreaterThanOrEqual(toolLog.components(separatedBy: "xcrun simctl bootstatus SIM-123 -b").count - 1, 2)
    }

    func testBootstrapRetryUsesTargetedCleanupAndThenSucceeds() throws {
        let e2e = try E2EScenario(scenario: .bootstrapRetry)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try result.jsonObject()
        XCTAssertEqual(json["result_class"] as? String, "success")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let diagnosticsPath = try XCTUnwrap(artifacts["diagnostics"] as? String)
        let diagnostics = try String(contentsOfFile: diagnosticsPath)
        XCTAssertTrue(diagnostics.contains("command=xcrun simctl diagnose -l"))
        XCTAssertTrue(diagnostics.contains("CoreSimulatorDiagnostic"))
        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun simctl diagnose -l"))
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl erase SIM-123"))
        XCTAssertFalse(toolLog.contains("shutdown all"))
        XCTAssertFalse(toolLog.contains("erase all"))
    }

    func testBootstrapRetryPreservesFirstAttemptResultBundle() throws {
        let e2e = try E2EScenario(scenario: .bootstrapRetryWithPartialResult)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try result.jsonObject()
        XCTAssertEqual(json["result_class"] as? String, "success")
        let jobID = try e2e.jobID(from: json)
        let jobDir = e2e.jobDir(jobID)
        let finalBundle = jobDir.appendingPathComponent("artifacts/result.xcresult")
        let finalSummary = finalBundle.appendingPathComponent("summary.json")
        let preservedBundle = jobDir.appendingPathComponent("artifacts/attempts/test-attempt-001/result.xcresult")
        let preservedSummary = preservedBundle.appendingPathComponent("summary.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalSummary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedSummary.path))
        XCTAssertNotEqual(finalBundle.path, preservedBundle.path)

        let finalSummaryJSON = try XCTUnwrap(parseJSON(String(contentsOf: finalSummary)) as? [String: Any])
        let preservedSummaryJSON = try XCTUnwrap(parseJSON(String(contentsOf: preservedSummary)) as? [String: Any])
        XCTAssertEqual(finalSummaryJSON["testsCount"] as? Int, 3)
        XCTAssertEqual(preservedSummaryJSON["testsCount"] as? Int, 0)

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: jobDir.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_class"] as? String, "success")
        XCTAssertEqual(runMetadata["result_bundle_path"] as? String, finalBundle.path)
        let metadataArtifacts = try XCTUnwrap(runMetadata["artifacts"] as? [String: Any])
        XCTAssertEqual(metadataArtifacts["xcresult"] as? String, finalBundle.path)

        let attempts = try XCTUnwrap(runMetadata["attempts"] as? [[String: Any]])
        XCTAssertEqual(attempts.count, 1)
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempt["phase"] as? String, "test")
        XCTAssertEqual(attempt["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(attempt["retry_reason"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(attempt["result_bundle"] as? String, preservedBundle.path)
        let attemptMetadata = try XCTUnwrap(attempt["metadata"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attemptMetadata))
        XCTAssertTrue(attemptMetadata.hasPrefix(jobDir.appendingPathComponent("artifacts/attempts/test-attempt-001").path))

        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let testCommands = commands.filter { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" }
        XCTAssertEqual(testCommands.count, 2)
        XCTAssertEqual((testCommands.first?["exit_code"] as? NSNumber)?.intValue, 74)
        XCTAssertEqual((testCommands.last?["exit_code"] as? NSNumber)?.intValue, 0)
    }

    func testExecutorBootsSimulatorBeforeBuildAndTest() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun simctl boot SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl bootstatus SIM-123 -b"))
    }

    func testResetPolicyShutdownCleansOnlyResolvedSimulatorAfterJob() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        reset_policy = "shutdown"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertFalse(toolLog.contains("shutdown all"))
        XCTAssertFalse(toolLog.contains("xcrun simctl erase SIM-123"))
    }

    func testExecutorWarnsAndContinuesWhenCompetingSimulatorTestProcessIsActive() throws {
        let e2e = try E2EScenario(scenario: .concurrentRunnerContention)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try result.jsonObject()
        XCTAssertEqual(json["result_class"] as? String, "success")
        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcodebuild -project"))
        let jobID = try e2e.jobID(from: json)
        let combinedLog = try String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("logs/combined.log"))
        let buildLog = try String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("logs/build.log"))
        XCTAssertTrue(combinedLog.contains("WARNING: Competing simulator-hosted test activity detected"))
        XCTAssertTrue(buildLog.contains("WARNING: Competing simulator-hosted test activity detected"))
    }
}
