// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest

final class CancellationE2ETests: XCTestCase {
    func testQueuedJobCanBeCanceledWithoutArtifactsOrLeases() throws {
        let e2e = try E2EScenario(scenario: .queuedCancellation)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let firstSubmit = try e2e.submit()
        XCTAssertEqual(firstSubmit.status, 0, "stderr: \(firstSubmit.stderr)")
        let firstJobPersisted = try waitUntil(timeout: 5) {
            let jobs = try runCLI(arguments: ["jobs", "--state-root", e2e.stateRoot.path, "--json"], environment: e2e.fakeTools.env)
            let parsed = try XCTUnwrap(parseJSON(jobs.stdout) as? [[String: Any]])
            return !parsed.isEmpty
        }
        XCTAssertTrue(firstJobPersisted)
        let firstJobStarted = try waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: e2e.fakeTools.root.appendingPathComponent("queued-cancellation-first-started").path)
        }
        XCTAssertTrue(firstJobStarted)

        let second = try e2e.submit()
        XCTAssertEqual(second.status, 0, "stderr: \(second.stderr)")

        var lastJobsOutput = ""
        let queuedObserved = try waitUntil(timeout: 5) {
            let jobs = try runCLI(arguments: ["jobs", "--state-root", e2e.stateRoot.path, "--json"], environment: e2e.fakeTools.env)
            lastJobsOutput = jobs.stdout
            let parsed = try XCTUnwrap(parseJSON(jobs.stdout) as? [[String: Any]])
            return parsed.contains { ($0["state"] as? String) == "queued" }
        }
        XCTAssertTrue(queuedObserved, "jobs output: \(lastJobsOutput)")
        let queuedJobs = try XCTUnwrap(parseJSON(lastJobsOutput) as? [[String: Any]])
        let secondJobID = try XCTUnwrap(queuedJobs.first(where: { ($0["state"] as? String) == "queued" })?["job_id"] as? String)

        let cancel = try e2e.cancel(secondJobID)
        let cancelJSON = try cancel.jsonObject()
        XCTAssertEqual(cancelJSON["state"] as? String, "canceled")
        try e2e.writeFakeToolMarker("release-queued-cancellation")

        let jobs = try runCLI(arguments: ["jobs", "--state-root", e2e.stateRoot.path, "--json"], environment: e2e.fakeTools.env)
        let jobsJSON = try XCTUnwrap(parseJSON(jobs.stdout) as? [[String: Any]])
        let firstJobID = try XCTUnwrap(jobsJSON.first(where: { ($0["job_id"] as? String) != secondJobID })?["job_id"] as? String, "jobs output: \(jobs.stdout)")
        let finished = try waitUntil(timeout: 10) {
            let firstJSON = try e2e.status(firstJobID)
            let secondJSON = try e2e.status(secondJobID)
            return (firstJSON["state"] as? String) == "succeeded" && (secondJSON["state"] as? String) == "canceled"
        }
        XCTAssertTrue(finished)

        let firstStatusJSON = try e2e.status(firstJobID)
        XCTAssertEqual(firstStatusJSON["state"] as? String, "succeeded")
        let secondStatusJSON = try e2e.status(secondJobID)
        XCTAssertEqual(secondStatusJSON["state"] as? String, "canceled")
        XCTAssertEqual(secondStatusJSON["result_class"] as? String, "canceled")

        let secondArtifactsJSON = try e2e.artifacts(secondJobID)
        XCTAssertTrue(secondArtifactsJSON["xcresult"] == nil || secondArtifactsJSON["xcresult"] is NSNull)
        XCTAssertTrue(secondArtifactsJSON["combinedLog"] == nil || secondArtifactsJSON["combinedLog"] is NSNull)
        XCTAssertTrue(secondArtifactsJSON["buildLog"] == nil || secondArtifactsJSON["buildLog"] is NSNull)
        XCTAssertTrue(secondArtifactsJSON["testLog"] == nil || secondArtifactsJSON["testLog"] is NSNull)
        XCTAssertTrue(secondArtifactsJSON["derivedData"] == nil || secondArtifactsJSON["derivedData"] is NSNull)

        let store = try e2e.stateStore()
        let secondRecord = try XCTUnwrap(store.fetchJob(id: secondJobID))
        XCTAssertNil(secondRecord.processID)
        XCTAssertNil(secondRecord.simulatorID)
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)

        let toolLog = try e2e.toolLog()
        XCTAssertFalse(toolLog.contains("XCSTEWARD_JOB_ID=\(secondJobID)"))
        XCTAssertFalse(toolLog.contains("job=\(secondJobID)"))
    }

    func testRunningJobCancellationTerminatesActiveXcodebuildAndRecordsCanceledSummary() throws {
        let e2e = try E2EScenario(scenario: .runningCancellation)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let jobID = try e2e.jobID(from: e2e.submitJSON())
        let buildStarted = try waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: e2e.fakeTools.root.appendingPathComponent("build-started").path)
        }
        let buildStartLog = try e2e.toolLog()
        XCTAssertTrue(buildStarted, buildStartLog)

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
            try e2e.toolLog().contains("xcodebuild received SIGTERM")
        }
        let terminationLog = try e2e.toolLog()
        XCTAssertTrue(observedTermination, terminationLog)

        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Build started"))

        let artifacts = try e2e.artifacts(jobID)
        XCTAssertNotNil(artifacts["combinedLog"])
        XCTAssertNotNil(artifacts["buildLog"])
        XCTAssertTrue(artifacts["xcresult"] == nil || artifacts["xcresult"] is NSNull)

        let runMetadata = try runMetadata(e2e, jobID: jobID)
        XCTAssertEqual(runMetadata["result_class"] as? String, "canceled")
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, false)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, true)
        XCTAssertEqual(runMetadata["simulator_id"] as? String, "SIM-123")
        XCTAssertEqual(runMetadata["result_bundle_path"] == nil || runMetadata["result_bundle_path"] is NSNull, true)

        let commands = try commands(in: runMetadata)
        let buildCommand = try command(in: commands, phase: "build", tool: "xcodebuild")
        XCTAssertEqual(integer(buildCommand["exit_code"]), 143)
        XCTAssertEqual(buildCommand["timed_out"] as? Bool, false)
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" })
    }

    func testRunningTestCancellationTerminatesActiveXcodebuildAndRecordsCanceledSummary() throws {
        let e2e = try E2EScenario(scenario: .testCancellation)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let jobID = try e2e.jobID(from: e2e.submitJSON())
        let testStarted = try waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: e2e.fakeTools.root.appendingPathComponent("test-started").path)
        }
        let testStartLog = try e2e.toolLog()
        XCTAssertTrue(testStarted, testStartLog)

        let liveArtifacts = try e2e.artifacts(jobID)
        let commandEventsPath = try XCTUnwrap(liveArtifacts["commandEvents"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: commandEventsPath))
        let liveEvents = try commandEvents(at: commandEventsPath)
        let eventDump = "\(liveEvents)"
        XCTAssertNotNil(
            liveEvents.first {
                ($0["event"] as? String) == "launching"
                    && ($0["phase"] as? String) == "test"
                    && ($0["command_line"] as? String)?.contains("test-without-building") == true
            },
            eventDump
        )
        XCTAssertNotNil(
            liveEvents.first {
                ($0["event"] as? String) == "started"
                    && ($0["phase"] as? String) == "test"
                    && integer($0["pid"]) != nil
            },
            eventDump
        )
        let liveLogs = try e2e.logs(jobID)
        XCTAssertTrue(liveLogs.contains("XCSteward starting test command: xcodebuild"), liveLogs)
        XCTAssertTrue(liveLogs.contains("test-without-building"), liveLogs)
        XCTAssertTrue(liveLogs.contains("XCSteward command events: \(commandEventsPath)"), liveLogs)

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
            try e2e.toolLog().contains("xcodebuild test received SIGTERM")
        }
        let terminationLog = try e2e.toolLog()
        XCTAssertTrue(observedTermination, terminationLog)

        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Build succeeded"))
        XCTAssertTrue(logs.contains("Testing started"))

        let artifacts = try e2e.artifacts(jobID)
        XCTAssertNotNil(artifacts["combinedLog"])
        XCTAssertNotNil(artifacts["buildLog"])
        XCTAssertNotNil(artifacts["testLog"])
        XCTAssertNotNil(artifacts["junit"])
        XCTAssertEqual(artifacts["commandEvents"] as? String, commandEventsPath)
        XCTAssertTrue(artifacts["xcresult"] == nil || artifacts["xcresult"] is NSNull)

        let runMetadata = try runMetadata(e2e, jobID: jobID)
        XCTAssertEqual(runMetadata["result_class"] as? String, "canceled")
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, false)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, true)
        XCTAssertEqual(runMetadata["simulator_id"] as? String, "SIM-123")
        XCTAssertEqual(runMetadata["result_bundle_path"] == nil || runMetadata["result_bundle_path"] is NSNull, true)
        XCTAssertNotNil(runMetadata["junit_path"])
        XCTAssertEqual(runMetadata["command_event_log_path"] as? String, commandEventsPath)

        let commands = try commands(in: runMetadata)
        let buildCommand = try command(in: commands, phase: "build", tool: "xcodebuild")
        XCTAssertEqual(integer(buildCommand["exit_code"]), 0)
        XCTAssertEqual(buildCommand["timed_out"] as? Bool, false)
        let testCommand = try command(in: commands, phase: "test", tool: "xcodebuild")
        XCTAssertEqual(integer(testCommand["exit_code"]), 143)
        XCTAssertEqual(testCommand["timed_out"] as? Bool, false)
        let finalEvents = try commandEvents(at: commandEventsPath)
        let finalEventDump = "\(finalEvents)"
        let finishedTestEvent = try XCTUnwrap(
            finalEvents.first { ($0["event"] as? String) == "finished" && ($0["phase"] as? String) == "test" },
            finalEventDump
        )
        XCTAssertEqual(integer(finishedTestEvent["exit_code"]), 143)
        XCTAssertEqual(finishedTestEvent["timed_out"] as? Bool, false)
    }

    func testPostTestArtifactParsingCancellationTerminatesXCResultProbeAndRecordsCanceledSummary() throws {
        let e2e = try E2EScenario(scenario: .postTestArtifactCancellation)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let jobID = try e2e.jobID(from: e2e.submitJSON())
        let artifactProbeStarted = try waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: e2e.fakeTools.root.appendingPathComponent("xcresult-summary-started").path)
        }
        let probeStartLog = try e2e.toolLog()
        XCTAssertTrue(artifactProbeStarted, probeStartLog)

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

        let observedProbeTermination = try waitUntil(timeout: 5) {
            try e2e.toolLog().contains("xcresulttool summary received SIGTERM")
        }
        let terminationLog = try e2e.toolLog()
        XCTAssertTrue(observedProbeTermination, terminationLog)

        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Build succeeded"))
        XCTAssertTrue(logs.contains("Tests succeeded"))

        let artifacts = try e2e.artifacts(jobID)
        let xcresult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(xcresult)/summary.json"))
        XCTAssertNotNil(artifacts["combinedLog"])
        XCTAssertNotNil(artifacts["buildLog"])
        XCTAssertNotNil(artifacts["testLog"])
        XCTAssertTrue(artifacts["junit"] == nil || artifacts["junit"] is NSNull)

        let runMetadata = try runMetadata(e2e, jobID: jobID)
        XCTAssertEqual(runMetadata["result_class"] as? String, "canceled")
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, false)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, true)
        XCTAssertEqual(runMetadata["simulator_id"] as? String, "SIM-123")
        XCTAssertEqual(runMetadata["result_bundle_path"] as? String, xcresult)
        XCTAssertTrue(runMetadata["junit_path"] == nil || runMetadata["junit_path"] is NSNull)

        let commands = try commands(in: runMetadata)
        let buildCommand = try command(in: commands, phase: "build", tool: "xcodebuild")
        XCTAssertEqual(integer(buildCommand["exit_code"]), 0)
        let testCommand = try command(in: commands, phase: "test", tool: "xcodebuild")
        XCTAssertEqual(integer(testCommand["exit_code"]), 0)
        let artifactCommand = try command(in: commands, phase: "artifact", tool: "xcrun")
        XCTAssertEqual(integer(artifactCommand["exit_code"]), 143)
        XCTAssertEqual(artifactCommand["timed_out"] as? Bool, false)
    }

    private func runMetadata(_ e2e: E2EScenario, jobID: String) throws -> [String: Any] {
        try XCTUnwrap(
            parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any]
        )
    }

    private func commands(in runMetadata: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
    }

    private func commandEvents(at path: String) throws -> [[String: Any]] {
        try String(contentsOfFile: path)
            .split(separator: "\n")
            .compactMap { (try? parseJSON(String($0))) as? [String: Any] }
    }

    private func command(in commands: [[String: Any]], phase: String, tool: String) throws -> [String: Any] {
        let commandDump = "\(commands)"
        return try XCTUnwrap(
            commands.first { ($0["phase"] as? String) == phase && ($0["tool"] as? String) == tool },
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
