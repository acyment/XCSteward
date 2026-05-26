import Foundation
import XCTest

final class CLIProgressTests: XCTestCase {
    func testSubmitWaitProgressWritesJSONLinesToStderrWithoutChangingFinalJSONStdout() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(body: """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """)

        let result = try e2e.submit(wait: true, extraArguments: ["--progress"])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let summary = try result.jsonObject()
        XCTAssertEqual(summary["state"] as? String, "succeeded")
        let events = try progressEvents(from: result.stderr)
        XCTAssertTrue(events.contains { $0["event"] as? String == "job_queued" })
        XCTAssertTrue(events.contains { $0["event"] as? String == "worker_ready" })
        let terminal = try XCTUnwrap(events.last { $0["event"] as? String == "job_terminal" })
        XCTAssertEqual(terminal["job_id"] as? String, summary["job_id"] as? String)
        XCTAssertEqual(terminal["state"] as? String, "succeeded")
    }

    func testDoctorProgressWritesCheckJSONLinesToStderrWithoutChangingReportStdout() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
                "--progress",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let report = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(report["overall_status"] as? String, "pass")
        let events = try progressEvents(from: result.stderr)
        XCTAssertTrue(events.contains {
            $0["event"] as? String == "doctor_check_started"
                && $0["check_id"] as? String == "global.state_root"
        })
        XCTAssertTrue(events.contains {
            $0["event"] as? String == "doctor_check_finished"
                && $0["check_id"] as? String == "global.state_root"
                && $0["status"] as? String == "pass"
        })
    }
}

private func progressEvents(from stderr: String) throws -> [[String: Any]] {
    try stderr
        .split(separator: "\n")
        .map { line in
            try XCTUnwrap(parseJSON(String(line)) as? [String: Any])
        }
}
