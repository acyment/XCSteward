import Foundation
import XCTest

final class TimeoutHardeningE2ETests: XCTestCase {
    func testBuildTimeoutIsClassifiedAndStopsBeforeTestRun() throws {
        let e2e = try E2EScenario(scenario: .buildTimeout)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        [timeouts]
        boot = 30
        build = 1
        test = 30
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "build_timeout")
        XCTAssertEqual(json["summary_line"] as? String, "Build timed out")
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-123")

        let jobID = try e2e.jobID(from: json)
        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Build started"))
        XCTAssertNil(try e2e.stateStore().simulatorLease(simulatorID: "SIM-123"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_class"] as? String, "build_timeout")
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, true)
        XCTAssertEqual(runMetadata["canceled"] as? Bool, false)
        XCTAssertEqual(runMetadata["result_bundle_path"] == nil || runMetadata["result_bundle_path"] is NSNull, true)

        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let commandDump = "\(commands)"
        let buildCommand = try XCTUnwrap(
            commands.first { ($0["phase"] as? String) == "build" && ($0["tool"] as? String) == "xcodebuild" },
            commandDump
        )
        XCTAssertEqual(buildCommand["timed_out"] as? Bool, true)
        XCTAssertEqual((buildCommand["timeout_seconds"] as? NSNumber)?.intValue, 1)
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" })
    }

    func testTestTimeoutIsClassifiedSeparatelyFromRunnerBootstrapFailure() throws {
        let e2e = try E2EScenario(scenario: .testTimeout)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        [timeouts]
        boot = 30
        build = 30
        test = 1
        """)

        let result = try e2e.submit(wait: true)

        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "test_timeout")
        XCTAssertEqual(json["summary_line"] as? String, "Tests timed out")
        let jobID = try e2e.jobID(from: json)
        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_class"] as? String, "test_timeout")
        XCTAssertEqual(runMetadata["timed_out"] as? Bool, true)
        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let testCommand = try XCTUnwrap(
            commands.first { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" },
            "\(commands)"
        )
        XCTAssertEqual(testCommand["timed_out"] as? Bool, true)
    }
}
