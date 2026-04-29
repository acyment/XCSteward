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
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertTrue(try store.acquireSimulatorLease(simulatorID: "SIM-123", jobID: "other-job", pid: getpid()))
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("already leased by another XCSteward job") == true)
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
        let heartbeatRefreshed = try waitUntil(timeout: 6, pollInterval: 0.1) {
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
        XCTAssertTrue(heartbeatRefreshed)

        let finished = try waitUntil(timeout: 15) {
            let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
            let statusJSON = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
            return (statusJSON["state"] as? String) == "succeeded"
        }
        XCTAssertTrue(finished)
        let leaseReleased = try waitUntil(timeout: 3, pollInterval: 0.1) {
            try store.simulatorLease(simulatorID: "SIM-123") == nil
        }
        XCTAssertTrue(leaseReleased)
    }
}
