import Foundation
import XCTest

final class WorkerLaunchE2ETests: XCTestCase {
    func testSubmitWaitThroughPATHUsesResolvedExecutableAndDoesNotLeaveQueuedOrphan() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )
        var environment = e2e.fakeTools.env
        let executableDirectory = try executableURL().deletingLastPathComponent().path
        environment["PATH"] = "\(executableDirectory):\(environment["PATH"] ?? "")"

        let result = try runCLIThroughPATH(
            arguments: [
                "--state-root", e2e.stateRoot.path,
                "submit",
                "--project", "demo",
                "--wait",
                "--json",
            ],
            environment: environment,
            currentDirectoryURL: e2e.repoRoot
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertEqual(result.stderr, "")
        let json = try result.jsonObject()
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        let jobID = try e2e.jobID(from: json)
        let jobs = try e2e.stateStore().listJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.id, jobID)
        XCTAssertEqual(jobs.first?.state.rawValue, "succeeded")
    }
}
