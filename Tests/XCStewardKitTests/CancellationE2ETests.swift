import Foundation
import XCTest

final class CancellationE2ETests: XCTestCase {
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
        let buildStarted = try waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: e2e.fakeTools.root.appendingPathComponent("build-started").path)
        }
        XCTAssertTrue(buildStarted)

        let cancel = try e2e.cancel(jobID)
        XCTAssertEqual(cancel.status, 0, "stderr: \(cancel.stderr)")

        let status = try e2e.waitForStatus(jobID, state: "canceled", timeout: 5)
        XCTAssertEqual(status["result_class"] as? String, "canceled")
        XCTAssertTrue(try e2e.toolLog().contains("xcodebuild received SIGTERM"))
    }
}
