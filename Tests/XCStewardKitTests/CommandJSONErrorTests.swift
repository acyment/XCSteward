import Foundation
import XCTest

final class CommandJSONErrorTests: XCTestCase {
    func testUsageErrorIsJSONWhenJSONWasRequested() throws {
        let result = try runCLI(arguments: ["submit", "--json"])

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["message"] as? String, "submit requires --project")
    }

    func testNotFoundErrorIsJSONWhenJSONWasRequested() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(arguments: ["status", "--state-root", stateRoot.path, "missing-job", "--json"])

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "not_found")
        XCTAssertEqual(error["message"] as? String, "Job missing-job not found")
    }

    func testInvalidProfileErrorIsJSONWhenJSONWasRequested() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try writeText(
            """
            repo_root = "\(repoRoot.path)"
            """,
            to: stateRoot.appendingPathComponent("projects/broken.toml")
        )
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)

        let result = try runCLI(
            arguments: ["doctor", "--state-root", stateRoot.path, "--project", "broken", "--json"],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "invalid_configuration")
        XCTAssertEqual(error["message"] as? String, "Profile broken is missing repo_root or scheme")
    }

    func testCleanupSizeBudgetUsageErrorIsJSONWhenJSONWasRequested() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(arguments: [
            "cleanup",
            "--state-root", stateRoot.path,
            "--max-total-size", "not-a-size",
            "--json",
        ])

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        let error = try commandError(from: result.stderr)
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["message"] as? String, "cleanup --max-total-size must be a non-negative size")
    }
}

private func commandError(from stderr: String) throws -> [String: Any] {
    let envelope = try XCTUnwrap(parseJSON(stderr) as? [String: Any])
    return try XCTUnwrap(envelope["error"] as? [String: Any])
}
