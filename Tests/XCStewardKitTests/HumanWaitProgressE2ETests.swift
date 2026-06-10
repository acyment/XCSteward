// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest
@testable import XCStewardKit

final class HumanWaitProgressE2ETests: XCTestCase {
    func testSubmitWaitHumanModePrintsContextAndProgress() throws {
        let e2e = try E2EScenario(scenario: .slowSuccess)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(
            wait: true,
            json: false,
            extraArguments: ["--wait-timeout", "30"]
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Queued job "), result.stdout)
        XCTAssertTrue(result.stdout.contains("Status: xcsteward --state-root \(e2e.stateRoot.path) status "), result.stdout)
        XCTAssertTrue(result.stdout.contains("Logs:   xcsteward --state-root \(e2e.stateRoot.path) logs "), result.stdout)
        XCTAssertTrue(result.stdout.contains("Follow: xcsteward --state-root \(e2e.stateRoot.path) logs "), result.stdout)
        XCTAssertTrue(result.stdout.contains("Job dir: \(e2e.stateRoot.appendingPathComponent("jobs").path)/"), result.stdout)
        XCTAssertTrue(result.stdout.contains("running"), result.stdout)
        XCTAssertTrue(result.stdout.contains("build") || result.stdout.contains("test"), result.stdout)
        XCTAssertTrue(result.stdout.contains("last event"), result.stdout)
        XCTAssertTrue(result.stdout.contains("logs/combined.log"), result.stdout)
        XCTAssertTrue(result.stdout.lowercased().contains("succeeded"), result.stdout)
        XCTAssertEqual(result.stderr, "")
    }

    func testStatusWatchHumanModePrintsQueuedRunningAndTerminalUpdates() throws {
        let e2e = try E2EScenario(scenario: .slowSuccess)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        _ = try e2e.submit(wait: false, json: true)
        let queued = try e2e.submitJSON(wait: false)
        let queuedJobID = try e2e.jobID(from: queued)

        let result = try runCLI(
            arguments: [
                "status",
                "--state-root", e2e.stateRoot.path,
                queuedJobID,
                "--watch",
                "--interval", "0.2",
            ],
            environment: e2e.fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("queued"), result.stdout)
        XCTAssertTrue(result.stdout.contains("running"), result.stdout)
        XCTAssertTrue(result.stdout.contains("succeeded"), result.stdout)
        XCTAssertTrue(result.stdout.contains("logs/combined.log"), result.stdout)
        XCTAssertEqual(result.stderr, "")
    }

    func testStatusWatchJSONPrintsNDJSONSummaries() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)
        let summary = try e2e.submitJSON(wait: true)
        let jobID = try e2e.jobID(from: summary)

        let result = try runCLI(
            arguments: [
                "status",
                "--state-root", e2e.stateRoot.path,
                jobID,
                "--watch",
                "--interval", "0.2",
                "--json",
            ],
            environment: e2e.fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 1, result.stdout)
        let watched = try XCTUnwrap(parseJSON(String(lines[0])) as? [String: Any])
        XCTAssertEqual(watched["job_id"] as? String, jobID)
        XCTAssertEqual(watched["state"] as? String, "succeeded")
        XCTAssertEqual(result.stderr, "")
    }

    func testLogsFollowPrintsExistingTerminalLog() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)
        let summary = try e2e.submitJSON(wait: true)
        let jobID = try e2e.jobID(from: summary)

        let result = try runCLI(
            arguments: ["logs", "--state-root", e2e.stateRoot.path, jobID, "--follow"],
            environment: e2e.fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Build succeeded"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Tests succeeded"), result.stdout)
        XCTAssertEqual(result.stderr, "")
    }

    func testLogsExplainPendingCombinedLogForRunningJob() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let jobDirectory = stateRoot.appendingPathComponent("jobs/job-without-log")
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        try store.createJob(JobRecord(
            id: "job-without-log",
            project: "demo",
            state: .running,
            resultClass: nil,
            request: JobRequest(
                project: "demo",
                testPlan: nil,
                onlyTesting: [],
                simulatorID: nil,
                metadata: [:],
                wait: false
            ),
            summary: nil,
            jobDirectory: jobDirectory.path,
            createdAt: Date().timeIntervalSince1970,
            startedAt: Date().timeIntervalSince1970,
            finishedAt: nil,
            processID: nil,
            simulatorID: "SIM-123",
            cancelRequested: false
        ))

        let result = try runCLI(arguments: ["logs", "--state-root", stateRoot.path, "job-without-log"])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Combined log is not available yet"), result.stdout)
        XCTAssertTrue(result.stdout.contains("simulator/bootstrap setup"), result.stdout)
        XCTAssertTrue(result.stdout.contains("status job-without-log --watch"), result.stdout)
        XCTAssertEqual(result.stderr, "")
    }
}
