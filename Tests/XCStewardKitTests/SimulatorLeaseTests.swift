import Darwin
import Foundation
import XCTest
@testable import XCStewardKit

final class SimulatorLeaseTests: XCTestCase {
    func testSuccessfulJobReleasesSimulatorLease() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }

    func testActiveSimulatorLeaseBlocksAnotherJobForSameUDID() throws {
        let e2e = try E2EScenario(scenario: .success)
        let store = try e2e.stateStore()
        XCTAssertTrue(try store.acquireSimulatorLease(simulatorID: "SIM-123", jobID: "other-job", pid: getpid()))
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
        XCTAssertTrue((json["summary_line"] as? String)?.contains("already leased by another XCSteward job") == true)

        let jobID = try e2e.jobID(from: json)
        let job = try XCTUnwrap(try store.fetchJob(id: jobID))
        XCTAssertNil(job.processID)
        XCTAssertEqual(job.simulatorID, "SIM-123")

        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("already leased by another XCSteward job"))
        let artifacts = try e2e.artifacts(jobID)
        XCTAssertNotNil(artifacts["combinedLog"])
        XCTAssertTrue(artifacts["xcresult"] == nil || artifacts["xcresult"] is NSNull)

        let runMetadata = try XCTUnwrap(
            parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any]
        )
        XCTAssertEqual(runMetadata["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(runMetadata["simulator_id"] as? String, "SIM-123")
        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "build" && ($0["tool"] as? String) == "xcodebuild" }, "\(commands)")
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" }, "\(commands)")

        let toolLog = try e2e.toolLog()
        XCTAssertFalse(toolLog.split(separator: "\n").contains { $0.hasPrefix("xcrun simctl boot SIM-123") })
        XCTAssertFalse(toolLog.split(separator: "\n").contains { $0.hasPrefix("xcrun simctl shutdown SIM-123") })
        XCTAssertFalse(toolLog.split(separator: "\n").contains { $0.hasPrefix("xcrun simctl erase SIM-123") })
        XCTAssertFalse(toolLog.contains("xcodebuild -project"))
        XCTAssertFalse(toolLog.contains("build-for-testing"))
        XCTAssertFalse(toolLog.contains("test-without-building"))
        XCTAssertEqual(try store.simulatorLease(simulatorID: "SIM-123")?.jobID, "other-job")
        try store.releaseSimulatorLease(simulatorID: "SIM-123")
    }

    func testStaleSimulatorLeaseIsRecoveredBeforeJobRuns() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertTrue(try store.acquireSimulatorLease(simulatorID: "SIM-123", jobID: "dead-job", pid: 0))
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }

    func testRunningJobRefreshesSimulatorLeaseHeartbeat() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .slowSuccess)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let submit = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--json",
            ],
            environment: fakeTools.env
        )
        XCTAssertEqual(submit.status, 0, "stderr: \(submit.stderr)")
        let submitJSON = try XCTUnwrap(parseJSON(submit.stdout) as? [String: Any])
        let jobID = try XCTUnwrap(submitJSON["job_id"] as? String)
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))

        var firstHeartbeat: Double?
        let heartbeatRefreshed = try waitUntil(timeout: 12, pollInterval: 0.1) {
            guard let lease = try store.simulatorLease(simulatorID: "SIM-123"),
                  lease.jobID == jobID else {
                return false
            }
            if firstHeartbeat == nil {
                firstHeartbeat = lease.heartbeat
                return false
            }
            return lease.heartbeat > (firstHeartbeat ?? 0) + 0.25
        }
        let heartbeatLog = FileManager.default.fileExists(atPath: fakeTools.log.path)
            ? try String(contentsOf: fakeTools.log)
            : "<missing fake tool log>"
        XCTAssertTrue(heartbeatRefreshed, heartbeatLog)

        let finished = try waitUntil(timeout: 30) {
            let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
            let statusJSON = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
            return (statusJSON["state"] as? String) == "succeeded"
        }
        let finishLog = FileManager.default.fileExists(atPath: fakeTools.log.path)
            ? try String(contentsOf: fakeTools.log)
            : "<missing fake tool log>"
        XCTAssertTrue(finished, finishLog)
        let leaseReleased = try waitUntil(timeout: 5, pollInterval: 0.1) {
            try store.simulatorLease(simulatorID: "SIM-123") == nil
        }
        let releaseLog = FileManager.default.fileExists(atPath: fakeTools.log.path)
            ? try String(contentsOf: fakeTools.log)
            : "<missing fake tool log>"
        XCTAssertTrue(leaseReleased, releaseLog)
    }
}
