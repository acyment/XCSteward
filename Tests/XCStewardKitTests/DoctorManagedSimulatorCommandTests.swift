import Foundation
import XCTest
@testable import XCStewardKit

final class DoctorManagedSimulatorCommandTests: XCTestCase {
    func testDoctorReportsMissingManagedSimulatorWithoutFix() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .listSchemes)
        try createProfile(
            name: "managed",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Managed Device"
            device_type = "iPhone 17 Pro"
            runtime = "iOS 18.0"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "managed", environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let managed = try result.check("project.managed_simulator")
        XCTAssertEqual(managed["auto_fixable"] as? Bool, true)
    }

    func testDoctorFixReportsManagedSimulatorRuntimeResolutionFailure() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .listSchemes)
        try createProfile(
            name: "managed",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Managed Device"
            device_type = "iPhone 17 Pro"
            runtime = "iOS 99.0"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "managed", fix: true, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let managed = try result.check("project.managed_simulator")
        XCTAssertEqual(managed["status"] as? String, "fail")
        XCTAssertEqual(managed["auto_fixable"] as? Bool, true)
        XCTAssertEqual(managed["fixed"] as? Bool, false)
        XCTAssertTrue((managed["message"] as? String)?.contains("unknown Simulator runtime 'iOS 99.0'") == true)
        XCTAssertTrue((managed["manual_action"] as? String)?.contains("CoreSimulator runtime availability") == true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(log.contains("xcrun simctl list devicetypes --json"))
        XCTAssertTrue(log.contains("xcrun simctl list runtimes --json"))
        XCTAssertFalse(log.contains("xcrun simctl create Managed Device"))
    }

    func testDoctorFixCreatesManagedSimulatorAndRecoversStaleLease() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .managedSimulatorCreateRequiresIdentifiers)
        try createProfile(
            name: "managed",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Managed Device"
            device_type = "iPhone 17 Pro"
            runtime = "iOS 18.0"
            """
        )
        try seedStaleLease(stateRoot: stateRoot)

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "managed", fix: true, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "pass")
        let managed = try result.check("project.managed_simulator")
        XCTAssertEqual(managed["status"] as? String, "pass")
        XCTAssertEqual(managed["fixed"] as? Bool, true)
        let workerLease = try result.check("global.worker_lease")
        XCTAssertEqual(workerLease["status"] as? String, "pass")
        XCTAssertEqual(workerLease["fixed"] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("stale-lease.json").path))
        let simulatorLeases = try result.check("global.simulator_leases")
        XCTAssertEqual(simulatorLeases["status"] as? String, "pass")
        XCTAssertEqual(simulatorLeases["fixed"] as? Bool, false)
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(log.contains("xcrun simctl list devicetypes --json"))
        XCTAssertTrue(log.contains("xcrun simctl list runtimes --json"))
        XCTAssertTrue(log.contains("xcrun simctl create Managed Device com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-18-0"))
        XCTAssertFalse(log.contains("xcrun simctl shutdown all"))
        XCTAssertFalse(log.contains("xcrun simctl delete unavailable"))
        XCTAssertFalse(log.contains("xcrun simctl delete "))
        XCTAssertFalse(log.contains("xcrun simctl erase "))
    }
}
