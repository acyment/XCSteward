import Foundation
import XCTest
@testable import XCStewardKit

final class ProfileLoaderTests: XCTestCase {
    func testLoadProfileTrimsRootStringFields() throws {
        let temp = try makeTempDirectory()
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try writeProfile(
            """
            repo_root = "  \(repoRoot.path)  "
            project_path = " App.xcodeproj "
            workspace_path = "  "
            scheme = " Demo "
            default_simulator_id = " SIM-123 "
            default_test_plan = " Stable "
            allowed_simulator_ids = [" SIM-123 ", " ", "SIM-456"]
            """,
            named: "trimmed",
            stateRoot: temp.appendingPathComponent("state")
        )

        let profile = try loadProfile(named: "trimmed", stateRoot: temp.appendingPathComponent("state"))

        XCTAssertEqual(profile.repoRoot, repoRoot.path)
        XCTAssertEqual(profile.projectPath, "App.xcodeproj")
        XCTAssertNil(profile.workspacePath)
        XCTAssertEqual(profile.scheme, "Demo")
        XCTAssertEqual(profile.defaultSimulatorID, "SIM-123")
        XCTAssertEqual(profile.defaultTestPlan, "Stable")
        XCTAssertEqual(profile.allowedSimulatorIDs, ["SIM-123", "SIM-456"])
    }

    func testLoadProfileAcceptsWorkspacePathInsteadOfProjectPath() throws {
        let temp = try makeTempDirectory()
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try writeProfile(
            """
            repo_root = "\(repoRoot.path)"
            workspace_path = " App.xcworkspace "
            project_path = " "
            scheme = "Demo"
            """,
            named: "workspace",
            stateRoot: temp.appendingPathComponent("state")
        )

        let profile = try loadProfile(named: "workspace", stateRoot: temp.appendingPathComponent("state"))

        XCTAssertNil(profile.projectPath)
        XCTAssertEqual(profile.workspacePath, "App.xcworkspace")
    }

    func testLoadProfileRejectsMissingOrAmbiguousBuildContainer() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        try writeProfile(
            """
            repo_root = "\(temp.path)"
            scheme = "Demo"
            """,
            named: "missing-container",
            stateRoot: stateRoot
        )

        XCTAssertThrowsError(try loadProfile(named: "missing-container", stateRoot: stateRoot)) { error in
            XCTAssertTrue(String(describing: error).contains("must set exactly one of project_path or workspace_path"))
        }

        try writeProfile(
            """
            repo_root = "\(temp.path)"
            project_path = "App.xcodeproj"
            workspace_path = "App.xcworkspace"
            scheme = "Demo"
            """,
            named: "ambiguous-container",
            stateRoot: stateRoot
        )

        XCTAssertThrowsError(try loadProfile(named: "ambiguous-container", stateRoot: stateRoot)) { error in
            XCTAssertTrue(String(describing: error).contains("must not set both project_path and workspace_path"))
        }
    }

    func testLoadProfileRejectsBlankRequiredRootStrings() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        try writeProfile(
            """
            repo_root = " "
            scheme = "Demo"
            """,
            named: "blank-root",
            stateRoot: stateRoot
        )

        XCTAssertThrowsError(try loadProfile(named: "blank-root", stateRoot: stateRoot)) { error in
            XCTAssertTrue(String(describing: error).contains("repo_root must be a non-empty string"))
        }

        try writeProfile(
            """
            repo_root = "\(temp.path)"
            scheme = " "
            """,
            named: "blank-scheme",
            stateRoot: stateRoot
        )

        XCTAssertThrowsError(try loadProfile(named: "blank-scheme", stateRoot: stateRoot)) { error in
            XCTAssertTrue(String(describing: error).contains("scheme must be a non-empty string"))
        }
    }

    func testLoadProfileKeepsExistingMissingRequiredFieldMessage() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        try writeProfile(
            """
            repo_root = "\(temp.path)"
            """,
            named: "missing-scheme",
            stateRoot: stateRoot
        )

        XCTAssertThrowsError(try loadProfile(named: "missing-scheme", stateRoot: stateRoot)) { error in
            XCTAssertEqual(String(describing: error), "Profile missing-scheme is missing repo_root or scheme")
        }
    }
}

private func loadProfile(named name: String, stateRoot: URL) throws -> ProjectProfile {
    let environment = AppEnvironment(paths: AppPaths(stateRoot: stateRoot))
    return try ProfileLoader(environment: environment).loadProfile(named: name)
}

private func writeProfile(_ text: String, named name: String, stateRoot: URL) throws {
    try writeText(text, to: stateRoot.appendingPathComponent("projects/\(name).toml"))
}
