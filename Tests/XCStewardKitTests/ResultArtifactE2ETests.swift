import Foundation
import XCTest

final class ResultArtifactE2ETests: XCTestCase {
    func testStatusLogsAndArtifactsCommandsExposeRecordedFiles() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let submitJSON = try e2e.submitJSON(wait: true)
        let jobID = try e2e.jobID(from: submitJSON)

        let status = try e2e.status(jobID)
        XCTAssertEqual(status["state"] as? String, "succeeded")

        let artifacts = try e2e.artifacts(jobID)
        let xcresult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(xcresult)/summary.json"))
        XCTAssertNotNil(artifacts["junit"])

        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Build succeeded"))
        XCTAssertTrue(logs.contains("Tests succeeded"))
    }
}
