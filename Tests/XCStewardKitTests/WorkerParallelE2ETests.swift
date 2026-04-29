import Foundation
import XCTest

final class WorkerParallelE2ETests: XCTestCase {
    func testConcurrentJobsRecordIndependentOutcomesAndArtifacts() throws {
        let e2e = try E2EScenario(
            scenario: .parallelMixedOutcomes,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try e2e.writeProfile(
            name: "demo-success",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-SUCCESS"
            """
        )
        try e2e.writeProfile(
            name: "demo-artifact",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-ARTIFACT"
            """
        )

        let successJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-success"))
        let artifactJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-artifact"))

        try e2e.waitForToolEvents(
            matching: { $0.contains("event start phase=test") },
            count: 2,
            timeout: 8
        )

        let successStatus = try e2e.waitForTerminal(successJobID, timeout: 15)
        let artifactStatus = try e2e.waitForTerminal(artifactJobID, timeout: 15)
        XCTAssertEqual(successStatus["state"] as? String, "succeeded")
        XCTAssertEqual(successStatus["result_class"] as? String, "success")
        XCTAssertEqual(artifactStatus["state"] as? String, "failed")
        XCTAssertEqual(artifactStatus["result_class"] as? String, "artifact_failure")

        let successArtifacts = try XCTUnwrap(successStatus["artifacts"] as? [String: Any])
        let artifactArtifacts = try XCTUnwrap(artifactStatus["artifacts"] as? [String: Any])
        let successXCResult = try XCTUnwrap(successArtifacts["xcresult"] as? String)
        let artifactXCResult = try XCTUnwrap(artifactArtifacts["xcresult"] as? String)
        XCTAssertNotEqual(successXCResult, artifactXCResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(successXCResult)/summary.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(artifactXCResult)/summary.json"))

        let store = try e2e.stateStore()
        XCTAssertEqual(try store.countRecentInfrastructureFailures(since: 0), 1)
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }
}
