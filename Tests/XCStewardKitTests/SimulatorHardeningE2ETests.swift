// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest

final class SimulatorHardeningE2ETests: XCTestCase {
    func testSimulatorDisappearingDuringBootFailsWithTargetedEvidence() throws {
        let e2e = try E2EScenario(scenario: .simulatorDisappearsDuringBoot)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-123")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("Unable to boot simulator SIM-123") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("Invalid device: SIM-123") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("before XCTest attached") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("environment failure") == true)

        let jobID = try e2e.jobID(from: json)
        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Unable to boot simulator SIM-123"))
        XCTAssertTrue(logs.contains("Invalid device: SIM-123"))
        XCTAssertNil(try e2e.stateStore().simulatorLease(simulatorID: "SIM-123"))

        let artifacts = try e2e.artifacts(jobID)
        XCTAssertNotNil(artifacts["diagnostics"])

        let runMetadata = try runMetadata(e2e, jobID: jobID)
        XCTAssertEqual(runMetadata["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, false)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, false)
        let commands = try commands(in: runMetadata)
        let bootCommand = try command(in: commands, tool: "xcrun", arguments: ["simctl", "boot", "SIM-123"])
        XCTAssertEqual(integer(bootCommand["exit_code"]), 70)
        XCTAssertEqual(bootCommand["timed_out"] as? Bool, false)
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "build" && ($0["tool"] as? String) == "xcodebuild" })
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" })

        let toolLog = try e2e.toolLog()
        XCTAssertFalse(toolLog.contains("xcrun simctl erase SIM-123"))
        XCTAssertFalse(toolLog.contains("xcrun simctl delete"))
        XCTAssertFalse(toolLog.contains("-destination id=SIM-123"))
        XCTAssertFalse(toolLog.contains("build-for-testing"))
        XCTAssertFalse(toolLog.contains("test-without-building"))
    }

    func testBootstatusFailureKeepsEvidenceAndDoesNotRunXcodebuild() throws {
        let e2e = try E2EScenario(scenario: .bootStatusFailure)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-123")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("Unable to confirm simulator boot status for SIM-123") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("Waiting on Data Migration") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("before XCTest attached") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("environment failure") == true)

        let jobID = try e2e.jobID(from: json)
        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Unable to confirm simulator boot status for SIM-123"))
        XCTAssertTrue(logs.contains("Waiting on Data Migration"))
        XCTAssertNil(try e2e.stateStore().simulatorLease(simulatorID: "SIM-123"))

        let artifacts = try e2e.artifacts(jobID)
        XCTAssertNotNil(artifacts["diagnostics"])

        let runMetadata = try runMetadata(e2e, jobID: jobID)
        XCTAssertEqual(runMetadata["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, false)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, false)
        let commands = try commands(in: runMetadata)
        let bootCommand = try command(in: commands, tool: "xcrun", arguments: ["simctl", "boot", "SIM-123"])
        XCTAssertEqual(integer(bootCommand["exit_code"]), 0)
        let bootstatusCommand = try command(in: commands, tool: "xcrun", arguments: ["simctl", "bootstatus", "SIM-123", "-b"])
        XCTAssertEqual(integer(bootstatusCommand["exit_code"]), 75)
        XCTAssertEqual(bootstatusCommand["timed_out"] as? Bool, false)
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "build" && ($0["tool"] as? String) == "xcodebuild" })
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" })

        let toolLog = try e2e.toolLog()
        XCTAssertFalse(toolLog.contains("xcrun simctl erase SIM-123"))
        XCTAssertFalse(toolLog.contains("xcrun simctl delete"))
        XCTAssertFalse(toolLog.contains("-destination id=SIM-123"))
        XCTAssertFalse(toolLog.contains("build-for-testing"))
        XCTAssertFalse(toolLog.contains("test-without-building"))
    }

    func testCancellationDuringSimulatorBootTerminatesBootAndReleasesLease() throws {
        let e2e = try E2EScenario(scenario: .simulatorBootCancellation)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let jobID = try e2e.jobID(from: e2e.submitJSON())
        let bootStarted = try waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: e2e.fakeTools.root.appendingPathComponent("simulator-boot-started").path)
        }
        let bootStartLog = try e2e.toolLog()
        XCTAssertTrue(bootStarted, bootStartLog)

        let store = try e2e.stateStore()
        let processTracked = try waitUntil(timeout: 3) {
            try store.fetchJob(id: jobID)?.processID != nil
        }
        XCTAssertTrue(processTracked)

        let cancel = try e2e.cancel(jobID)
        XCTAssertEqual(cancel.status, 0, "stderr: \(cancel.stderr)")

        let status = try e2e.waitForStatus(jobID, state: "canceled", timeout: 5)
        XCTAssertEqual(status["result_class"] as? String, "canceled")
        XCTAssertEqual(status["summary_line"] as? String, "Canceled")
        XCTAssertEqual(status["simulator_id"] as? String, "SIM-123")
        let leaseReleased = try waitUntil(timeout: 5) {
            try store.simulatorLease(simulatorID: "SIM-123") == nil
        }
        XCTAssertTrue(leaseReleased)

        let observedTermination = try waitUntil(timeout: 5) {
            try e2e.toolLog().contains("simctl boot received SIGTERM")
        }
        let terminationLog = try e2e.toolLog()
        XCTAssertTrue(observedTermination, terminationLog)

        let artifacts = try e2e.artifacts(jobID)
        XCTAssertNotNil(artifacts["combinedLog"])

        let runMetadata = try runMetadata(e2e, jobID: jobID)
        XCTAssertEqual(runMetadata["result_class"] as? String, "canceled")
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, false)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, true)
        let commands = try commands(in: runMetadata)
        let bootCommand = try command(in: commands, tool: "xcrun", arguments: ["simctl", "boot", "SIM-123"])
        XCTAssertEqual(integer(bootCommand["exit_code"]), 143)
        XCTAssertEqual(bootCommand["timed_out"] as? Bool, false)
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "build" && ($0["tool"] as? String) == "xcodebuild" })
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" })
    }

    func testXcodebuildUnavailableFailsBeforeSimulatorMutation() throws {
        let e2e = try E2EScenario(scenario: .xcodebuildUnavailable)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-123")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("Unable to resolve xcodebuild") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("unable to find utility") == true)

        let jobID = try e2e.jobID(from: json)
        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Unable to resolve xcodebuild"))
        XCTAssertTrue(logs.contains("unable to find utility"))
        XCTAssertNil(try e2e.stateStore().simulatorLease(simulatorID: "SIM-123"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let preflight = try XCTUnwrap(commands.first {
            ($0["tool"] as? String) == "xcrun" &&
                ($0["arguments"] as? [String]) == ["--find", "xcodebuild"]
        })
        XCTAssertEqual(preflight["exit_code"] as? Int, 72)
        XCTAssertEqual(runMetadata["result_class"] as? String, "runner_bootstrap_failure")

        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun --find xcodebuild"))
        XCTAssertFalse(toolLog.contains("xcrun simctl list devices --json"))
        XCTAssertFalse(toolLog.split(separator: "\n").contains { $0.hasPrefix("xcrun simctl boot ") })
        XCTAssertFalse(toolLog.split(separator: "\n").contains { $0.hasPrefix("xcrun simctl shutdown SIM-123") })
        XCTAssertFalse(toolLog.split(separator: "\n").contains { $0.hasPrefix("xcrun simctl erase SIM-123") })
        XCTAssertFalse(toolLog.contains("-destination id=SIM-123"))
        XCTAssertFalse(toolLog.contains("xcodebuild -project"))
    }

    func testInvalidDefaultSimulatorIDFailsBeforeSimulatorMutation() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-MISSING"
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-MISSING")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("Configured simulator SIM-MISSING") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("refusing to fall back") == true)

        let jobID = try e2e.jobID(from: json)
        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Configured simulator SIM-MISSING"))
        XCTAssertNil(try e2e.stateStore().simulatorLease(simulatorID: "SIM-MISSING"))

        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun simctl list devices --json"))
        XCTAssertFalse(toolLog.split(separator: "\n").contains { $0.hasPrefix("xcrun simctl boot ") })
        XCTAssertFalse(toolLog.split(separator: "\n").contains { $0.hasPrefix("xcrun simctl shutdown SIM-MISSING") })
        XCTAssertFalse(toolLog.split(separator: "\n").contains { $0.hasPrefix("xcrun simctl erase SIM-MISSING") })
        XCTAssertFalse(toolLog.contains("-destination id=SIM-MISSING"))
    }

    private func runMetadata(_ e2e: E2EScenario, jobID: String) throws -> [String: Any] {
        let metadataURL = e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json")
        let metadataExists = try waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: metadataURL.path)
        }
        XCTAssertTrue(metadataExists)
        return try XCTUnwrap(
            parseJSON(String(contentsOf: metadataURL)) as? [String: Any]
        )
    }

    private func commands(in runMetadata: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
    }

    private func command(in commands: [[String: Any]], tool: String, arguments: [String]) throws -> [String: Any] {
        let commandDump = "\(commands)"
        return try XCTUnwrap(
            commands.first {
                ($0["tool"] as? String) == tool &&
                    ($0["arguments"] as? [String]) == arguments
            },
            commandDump
        )
    }

    private func integer(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }
}
