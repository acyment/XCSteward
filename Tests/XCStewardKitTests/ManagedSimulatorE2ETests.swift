import Foundation
import XCTest

final class ManagedSimulatorE2ETests: XCTestCase {
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
}
