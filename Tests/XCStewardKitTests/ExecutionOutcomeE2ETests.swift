// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest

final class ExecutionOutcomeE2ETests: XCTestCase {
    func testPlaceholderIOSSimulatorDestinationIsNotClassifiedAsMacOSOnly() throws {
        let e2e = try E2EScenario(scenario: .placeholderIOSSimulatorDestination)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let result = try e2e.submit(wait: true)

        XCTAssertEqual(result.status, 0, result.stderr)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        let jobID = try e2e.jobID(from: json)
        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let commandLines = commands.compactMap { $0["command_line"] as? String }.joined(separator: "\n")
        XCTAssertTrue(commandLines.contains("-showdestinations"))
        XCTAssertTrue(commandLines.contains("simctl list devices"))
        XCTAssertTrue(commandLines.contains("build-for-testing"))
        XCTAssertNotEqual(json["result_class"] as? String, "unsupported_destination")
    }

    func testMacOSOnlyDestinationFailsBeforeSimulatorMutation() throws {
        let e2e = try E2EScenario(scenario: .macOSOnlyDestination)
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
        XCTAssertEqual(json["result_class"] as? String, "unsupported_destination")
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("Native macOS app destinations are outside XCSteward public-alpha support") == true)
        XCTAssertTrue((json["simulator_id"] == nil) || (json["simulator_id"] is NSNull) || (json["simulator_id"] as? String) == "")

        let jobID = try e2e.jobID(from: json)
        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_class"] as? String, "unsupported_destination")
        XCTAssertEqual(runMetadata["state"] as? String, "failed")
        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let commandLines = commands.compactMap { $0["command_line"] as? String }.joined(separator: "\n")
        XCTAssertTrue(commandLines.contains("xcodebuild -project"))
        XCTAssertTrue(commandLines.contains("-showdestinations"))
        XCTAssertFalse(commandLines.contains("simctl list devices"))
        XCTAssertFalse(commandLines.contains("simctl boot"))
        XCTAssertFalse(commandLines.contains("build-for-testing"))
        XCTAssertFalse(try e2e.toolLog().contains("xcrun simctl"))
        XCTAssertFalse(try e2e.toolLog().contains("build-for-testing"))

        let store = try e2e.stateStore()
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }

    func testRunnerConfigurationFailureWithXCResultIsNotClassifiedAsTestFailure() throws {
        let e2e = try E2EScenario(scenario: .runnerConfigurationFailureWithXCResult)
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
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertNotEqual(json["result_class"] as? String, "test_failure")
    }

    func testLaunchdSimFailureAfterBuildIsEnvironmentFailureBeforeXCTestAttached() throws {
        let e2e = try E2EScenario(scenario: .launchdSimTestBootstrapFailure)
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
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertNotEqual(json["result_class"] as? String, "test_failure")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("before XCTest attached") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("environment failure") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("launchd_sim") == true)
        XCTAssertTrue((json["summary_line"] as? String)?.contains("xcrun simctl erase SIM-123") == true)

        let jobID = try e2e.jobID(from: json)
        let statusJSON = try e2e.status(jobID)
        XCTAssertEqual(statusJSON["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertTrue((statusJSON["summary_line"] as? String)?.contains("launchd_sim") == true)

        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Testing started"), logs)
        XCTAssertTrue(logs.contains("Failed to start launchd_sim"), logs)

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_class"] as? String, "runner_bootstrap_failure")
        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        XCTAssertTrue(commands.contains { command in
            (command["phase"] as? String) == "build" &&
                (command["tool"] as? String) == "xcodebuild" &&
                (command["exit_code"] as? NSNumber)?.intValue == 0
        }, "\(commands)")
        let testCommands = commands.filter { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" }
        XCTAssertEqual(testCommands.count, 2, "\(commands)")
        XCTAssertEqual((testCommands.first?["exit_code"] as? NSNumber)?.intValue, 65)
        XCTAssertEqual((testCommands.last?["exit_code"] as? NSNumber)?.intValue, 65)
        XCTAssertTrue(try e2e.toolLog().contains("xcrun simctl erase SIM-123"))
    }

    func testBuildFailureIsClassified() throws {
        let e2e = try E2EScenario(scenario: .buildFailure)
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
        XCTAssertEqual(json["result_class"] as? String, "build_failure")
        XCTAssertEqual(json["state"] as? String, "failed")
        let jobID = try e2e.jobID(from: json)
        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_class"] as? String, "build_failure")
        XCTAssertEqual(runMetadata["state"] as? String, "failed")
        XCTAssertEqual((runMetadata["exit_code"] as? NSNumber)?.intValue, 65)
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, false)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, false)
        XCTAssertEqual(runMetadata["result_bundle_path"] == nil || runMetadata["result_bundle_path"] is NSNull, true)
        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let commandDump = "\(commands)"
        let buildCommand = try XCTUnwrap(
            commands.first { ($0["phase"] as? String) == "build" && ($0["tool"] as? String) == "xcodebuild" },
            commandDump
        )
        XCTAssertEqual((buildCommand["exit_code"] as? NSNumber)?.intValue, 65)
        XCTAssertEqual(buildCommand["timed_out"] as? Bool, false)
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" })
    }
}
