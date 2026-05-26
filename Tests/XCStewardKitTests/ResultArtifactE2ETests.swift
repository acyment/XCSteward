import Foundation
import XCTest

final class ResultArtifactE2ETests: XCTestCase {
    func testMissingXCResultAfterSuccessfulTestCommandIsArtifactFailureWithEvidence() throws {
        let e2e = try E2EScenario(scenario: .missingXCResultSuccess)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let result = try e2e.submit(wait: true)

        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "artifact_failure")
        XCTAssertEqual(json["summary_line"] as? String, "Artifacts were missing or invalid")
        XCTAssertNil(json["counts"])

        let jobID = try e2e.jobID(from: json)
        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Build succeeded"))
        XCTAssertTrue(logs.contains("Tests succeeded without result bundle"))
        XCTAssertNil(try e2e.stateStore().simulatorLease(simulatorID: "SIM-123"))

        let artifacts = try e2e.artifacts(jobID)
        XCTAssertTrue(artifacts["xcresult"] == nil || artifacts["xcresult"] is NSNull)
        XCTAssertNotNil(artifacts["combinedLog"])
        XCTAssertNotNil(artifacts["testLog"])
        XCTAssertNotNil(artifacts["junit"])
        XCTAssertNotNil(artifacts["diagnostics"])

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_class"] as? String, "artifact_failure")
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, false)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, false)
        XCTAssertEqual(runMetadata["result_bundle_path"] == nil || runMetadata["result_bundle_path"] is NSNull, true)
        XCTAssertNotNil(runMetadata["junit_path"])
        let metadataArtifacts = try XCTUnwrap(runMetadata["artifacts"] as? [String: Any])
        XCTAssertNotNil(metadataArtifacts["diagnostics"])

        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let commandDump = "\(commands)"
        let testCommand = try XCTUnwrap(
            commands.first { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" },
            commandDump
        )
        XCTAssertEqual((testCommand["exit_code"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(testCommand["timed_out"] as? Bool, false)
    }

    func testSuccessfulTestRunWithCorruptXCResultIsArtifactFailure() throws {
        let e2e = try E2EScenario(scenario: .corruptXCResultSuccess)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let result = try e2e.submit(wait: true)

        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "artifact_failure")
        XCTAssertEqual(json["summary_line"] as? String, "Artifacts were missing or invalid")
        XCTAssertNil(json["counts"])
        let jobID = try e2e.jobID(from: json)
        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_class"] as? String, "artifact_failure")
        XCTAssertEqual(runMetadata["result_bundle_path"] as? String, e2e.jobDir(jobID).appendingPathComponent("artifacts/result.xcresult").path)
        let warnings = try XCTUnwrap(runMetadata["probe_warnings"] as? [[String: Any]])
        XCTAssertTrue(warnings.contains { ($0["source"] as? String) == "xcresulttool.summary" })
    }

    func testSuccessfulTestRunWithTimedOutXCResultSummaryProbeRemainsSuccessWithWarning() throws {
        let e2e = try E2EScenario(
            scenario: .xcresultSummaryTimeoutSuccess,
            extraEnv: ["XCSTEWARD_XCRESULT_PROBE_TIMEOUT_SECONDS": "1"]
        )
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let result = try e2e.submit(wait: true, extraArguments: ["--wait-timeout", "30"])

        XCTAssertEqual(result.status, 0, result.stderr)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        XCTAssertEqual(json["summary_line"] as? String, "Tests succeeded")
        XCTAssertEqual((json["exit_code"] as? NSNumber)?.intValue, 0)
        XCTAssertNil(json["counts"])

        let jobID = try e2e.jobID(from: json)
        let artifacts = try e2e.artifacts(jobID)
        let xcresult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(xcresult)/summary.json"))
        XCTAssertNotNil(artifacts["junit"])
        XCTAssertNil(try e2e.stateStore().simulatorLease(simulatorID: "SIM-123"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["state"] as? String, "succeeded")
        XCTAssertEqual(runMetadata["result_class"] as? String, "success")
        XCTAssertEqual(runMetadata["result_bundle_path"] as? String, xcresult)
        let warnings = try XCTUnwrap(runMetadata["probe_warnings"] as? [[String: Any]])
        let summaryWarnings = warnings.filter { ($0["source"] as? String) == "xcresulttool.summary" }
        XCTAssertFalse(summaryWarnings.isEmpty)
        XCTAssertTrue(summaryWarnings.allSatisfy { $0["timed_out"] as? Bool == true })

        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let artifactCommands = commands.filter { ($0["phase"] as? String) == "artifact" && ($0["tool"] as? String) == "xcrun" }
        XCTAssertEqual(artifactCommands.count, 2)
        XCTAssertTrue(artifactCommands.allSatisfy { $0["timed_out"] as? Bool == true })
    }

    func testJUnitGenerationFailureAfterSuccessfulTestsIsArtifactFailureWithEvidence() throws {
        let e2e = try E2EScenario(scenario: .junitGenerationFailure)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let result = try e2e.submit(wait: true)

        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "artifact_failure")
        XCTAssertEqual(json["summary_line"] as? String, "Artifacts were missing or invalid")
        XCTAssertEqual((json["counts"] as? [String: Any])?["testsRun"] as? Int, 3)
        XCTAssertEqual((json["exit_code"] as? NSNumber)?.intValue, 0)

        let jobID = try e2e.jobID(from: json)
        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Tests succeeded but JUnit path is blocked"))
        XCTAssertTrue(logs.contains("Unable to write JUnit report"))
        XCTAssertNil(try e2e.stateStore().simulatorLease(simulatorID: "SIM-123"))

        let artifacts = try e2e.artifacts(jobID)
        let xcresult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(xcresult)/summary.json"))
        XCTAssertTrue(artifacts["junit"] == nil || artifacts["junit"] is NSNull)
        XCTAssertNotNil(artifacts["combinedLog"])
        XCTAssertNotNil(artifacts["testLog"])
        XCTAssertNotNil(artifacts["diagnostics"])

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_class"] as? String, "artifact_failure")
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, false)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, false)
        XCTAssertEqual(runMetadata["result_bundle_path"] as? String, xcresult)
        XCTAssertTrue(runMetadata["junit_path"] == nil || runMetadata["junit_path"] is NSNull)

        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let commandDump = "\(commands)"
        let testCommand = try XCTUnwrap(
            commands.first { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" },
            commandDump
        )
        XCTAssertEqual((testCommand["exit_code"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(testCommand["timed_out"] as? Bool, false)
    }

    func testStatusLogsAndArtifactsCommandsExposeRecordedFiles() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let submitJSON = try e2e.submitJSON(wait: true)
        let jobID = try e2e.jobID(from: submitJSON)

        let status = try e2e.status(jobID)
        XCTAssertEqual(status["state"] as? String, "succeeded")

        let artifacts = try e2e.artifacts(jobID)
        let xcresult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(xcresult)/summary.json"))
        XCTAssertNotNil(artifacts["junit"])

        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Build succeeded"))
        XCTAssertTrue(logs.contains("Tests succeeded"))
    }
}
