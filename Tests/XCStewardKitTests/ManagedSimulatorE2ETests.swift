import Foundation
import XCTest

final class ManagedSimulatorE2ETests: XCTestCase {
    func testManagedSimulatorParsingUsesUDIDInsteadOfStatusText() throws {
        let e2e = try E2EScenario(scenario: .managedSimulatorStatusLine)
        try e2e.writeProfile(
            name: "managed",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Publiqueitor Test iPhone 17 Pro"
            device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
            runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
            """
        )

        let result = try e2e.submit(project: "managed", wait: true)
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try result.jsonObject()
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-123")

        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("-destination id=SIM-123"))
        XCTAssertFalse(toolLog.contains("-destination id=Shutdown"))
    }

    func testManagedSimulatorCreateFailureDoesNotUseErrorOutputAsSimulatorID() throws {
        let e2e = try E2EScenario(scenario: .managedSimulatorCreateFailure)
        try e2e.writeProfile(
            name: "managed",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Broken Test iPhone"
            device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
            runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
            """
        )

        let result = try e2e.submit(project: "managed", wait: true)
        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("CoreSimulator failed to create device") == true)

        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun simctl create Broken Test iPhone"))
        XCTAssertFalse(toolLog.contains("-destination id=CoreSimulator failed to create device"))
    }

    func testManagedSimulatorCreateSuccessRequiresSingleUDIDOutput() throws {
        let e2e = try E2EScenario(scenario: .managedSimulatorCreateNoisySuccess)
        try e2e.writeProfile(
            name: "managed",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Noisy Test iPhone"
            device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
            runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
            """
        )

        let result = try e2e.submit(project: "managed", wait: true)
        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("expected a single simulator UDID") == true)

        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun simctl create Noisy Test iPhone"))
        XCTAssertFalse(toolLog.contains("-destination id=CoreSimulator warning"))
    }

    func testManagedSimulatorResolutionCanBeCanceledWhileSimctlIsRunning() throws {
        let e2e = try E2EScenario(scenario: .managedSimulatorListHangs)
        try e2e.writeProfile(
            name: "managed",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Managed Hanging iPhone"
            device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
            runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
            """
        )

        let submit = try e2e.submit(project: "managed")
        XCTAssertEqual(submit.status, 0, "stderr: \(submit.stderr)")
        let jobID = try e2e.jobID(from: submit.jsonObject())

        let listStarted = try waitUntil(timeout: 5) {
            FileManager.default.fileExists(
                atPath: e2e.fakeTools.root.appendingPathComponent("managed-list-started").path
            )
        }
        XCTAssertTrue(listStarted)

        let cancel = try e2e.cancel(jobID)
        XCTAssertEqual(cancel.status, 0, "stderr: \(cancel.stderr)")

        let canceled = try waitUntil(timeout: 5) {
            try e2e.status(jobID)["state"] as? String == "canceled"
        }
        XCTAssertTrue(canceled)

        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("managed simctl list received SIGTERM"))
        XCTAssertFalse(toolLog.contains("xcrun simctl create Managed Hanging iPhone"))
    }
}
