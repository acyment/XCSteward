// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest
@testable import XCStewardKit

final class DoctorStateHealthCommandTests: XCTestCase {
    func testDoctorIgnoresXcodeBuildMCPProcessWhenCheckingRunnerContention() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .xcodebuildMCPProcess)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        let contention = try result.check("global.concurrent_runner_contention")
        XCTAssertEqual(contention["status"] as? String, "pass")
    }

    func testDoctorIgnoresIdleSimulatorAppWhenCheckingRunnerContention() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .simulatorAppProcess)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        let contention = try result.check("global.concurrent_runner_contention")
        XCTAssertEqual(contention["status"] as? String, "pass")
    }

    func testDoctorFailsWhenStaleSimulatorLeaseExists() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertTrue(try store.acquireSimulatorLease(simulatorID: "SIM-STALE", jobID: "dead-job", pid: 0))

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let leases = try result.check("global.simulator_leases")
        XCTAssertEqual(leases["status"] as? String, "fail")
        XCTAssertEqual(leases["auto_fixable"] as? Bool, true)
        XCTAssertTrue((leases["message"] as? String)?.contains("SIM-STALE") == true)
    }

    func testDoctorFixRecoversStaleSimulatorLeases() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertTrue(try store.acquireSimulatorLease(simulatorID: "SIM-STALE", jobID: "dead-job", pid: 0))

        let result = try runDoctorCommand(stateRoot: stateRoot, fix: true, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "pass")
        let leases = try result.check("global.simulator_leases")
        XCTAssertEqual(leases["status"] as? String, "pass")
        XCTAssertEqual(leases["fixed"] as? Bool, true)
        XCTAssertTrue((leases["message"] as? String)?.contains("Recovered 1 stale simulator lease") == true)
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }

    func testDoctorWarnsWhenCompetingLocalRunnerProcessesAreDetected() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .concurrentRunnerContention)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let contention = try result.check("global.concurrent_runner_contention")
        XCTAssertEqual(contention["status"] as? String, "warn")
        XCTAssertEqual(contention["auto_fixable"] as? Bool, false)
        XCTAssertEqual(contention["fixed"] as? Bool, false)
        XCTAssertTrue((contention["message"] as? String)?.contains("Competing") == true)
        XCTAssertTrue((contention["message"] as? String)?.contains("xcodebuild -scheme Demo test") == true)
        let manualAction = contention["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Wait for the competing simulator activity") == true)
        XCTAssertTrue(manualAction?.contains("route it through XCSteward") == true)
    }

    func testDoctorWarnsWhenProcessListingProbeCannotRun() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingProcessLister)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let contention = try result.check("global.concurrent_runner_contention")
        XCTAssertEqual(contention["status"] as? String, "warn")
        XCTAssertEqual(contention["auto_fixable"] as? Bool, false)
        XCTAssertEqual(contention["fixed"] as? Bool, false)
        XCTAssertTrue((contention["message"] as? String)?.contains("Unable to determine") == true)
        let manualAction = contention["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Inspect active xcodebuild") == true)
        XCTAssertTrue(manualAction?.contains("simctl processes manually") == true)
    }
}
