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

    func testLoadProfileSupportsInlineCommentsOutsideStrings() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try writeProfile(
            """
            # Profile comments are allowed.
            repo_root = "\(repoRoot.path)" # root comment
            project_path = "App#Debug.xcodeproj" # keep hash inside the string
            scheme = "Demo # UI" # trailing comment
            allowed_simulator_ids = ["SIM-123", "SIM#456"] # trailing array comment

            [parallel] # section comment
            max_workers = 1 # value comment
            """,
            named: "inline-comments",
            stateRoot: stateRoot
        )

        let profile = try loadProfile(named: "inline-comments", stateRoot: stateRoot)

        XCTAssertEqual(profile.repoRoot, repoRoot.path)
        XCTAssertEqual(profile.projectPath, "App#Debug.xcodeproj")
        XCTAssertEqual(profile.scheme, "Demo # UI")
        XCTAssertEqual(profile.allowedSimulatorIDs, ["SIM-123", "SIM#456"])
        XCTAssertEqual(profile.parallel.maxWorkers, 1)
    }

    func testLoadProfileParsesQuotedArrayValuesContainingCommas() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try writeProfile(
            """
            repo_root = "\(repoRoot.path)"
            project_path = "App.xcodeproj"
            scheme = "Demo"
            allowed_simulator_ids = ["SIM,123", "SIM-456",]
            """,
            named: "array-commas",
            stateRoot: stateRoot
        )

        let profile = try loadProfile(named: "array-commas", stateRoot: stateRoot)

        XCTAssertEqual(profile.allowedSimulatorIDs, ["SIM,123", "SIM-456"])
    }

    func testLoadProfileRejectsUnquotedArrayValues() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try writeProfile(
            """
            repo_root = "\(repoRoot.path)"
            project_path = "App.xcodeproj"
            scheme = "Demo"
            allowed_simulator_ids = [SIM-123]
            """,
            named: "unquoted-array",
            stateRoot: stateRoot
        )

        XCTAssertThrowsError(try loadProfile(named: "unquoted-array", stateRoot: stateRoot)) { error in
            XCTAssertTrue(String(describing: error).contains("TOML arrays must contain quoted strings"))
        }
    }

    func testLoadProfileRejectsWrongTypedKnownValues() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)

        let cases: [(name: String, body: String, expected: String)] = [
            (
                "root-string",
                """
                repo_root = 123
                project_path = "App.xcodeproj"
                scheme = "Demo"
                """,
                "repo_root must be a string"
            ),
            (
                "optional-root-string",
                """
                repo_root = "\(repoRoot.path)"
                project_path = 123
                scheme = "Demo"
                """,
                "project_path must be a string"
            ),
            (
                "root-array",
                """
                repo_root = "\(repoRoot.path)"
                project_path = "App.xcodeproj"
                scheme = "Demo"
                allowed_simulator_ids = "SIM-123"
                """,
                "allowed_simulator_ids must be an array of strings"
            ),
            (
                "parallel-integer",
                """
                repo_root = "\(repoRoot.path)"
                project_path = "App.xcodeproj"
                scheme = "Demo"

                [parallel]
                max_workers = "one"
                """,
                "parallel.max_workers must be an integer"
            ),
            (
                "parallel-bool",
                """
                repo_root = "\(repoRoot.path)"
                project_path = "App.xcodeproj"
                scheme = "Demo"

                [parallel]
                exact_workers = "false"
                """,
                "parallel.exact_workers must be a boolean"
            ),
            (
                "timeouts-integer",
                """
                repo_root = "\(repoRoot.path)"
                project_path = "App.xcodeproj"
                scheme = "Demo"

                [timeouts]
                build = "fast"
                """,
                "timeouts.build must be an integer"
            ),
            (
                "test-timeouts-bool",
                """
                repo_root = "\(repoRoot.path)"
                project_path = "App.xcodeproj"
                scheme = "Demo"

                [test_timeouts]
                enabled = "yes"
                """,
                "test_timeouts.enabled must be a boolean"
            ),
            (
                "test-retries-integer",
                """
                repo_root = "\(repoRoot.path)"
                project_path = "App.xcodeproj"
                scheme = "Demo"

                [test_retries]
                iterations = "two"
                """,
                "test_retries.iterations must be an integer"
            ),
            (
                "destination-integer",
                """
                repo_root = "\(repoRoot.path)"
                project_path = "App.xcodeproj"
                scheme = "Demo"

                [destination]
                timeout = "slow"
                """,
                "destination.timeout must be an integer"
            ),
            (
                "managed-simulator-bool",
                """
                repo_root = "\(repoRoot.path)"
                project_path = "App.xcodeproj"
                scheme = "Demo"

                [managed_simulator]
                name = "Demo"
                device_type = "iPhone 17 Pro"
                runtime = "iOS 26.5"
                clone_for_shards = "yes"
                """,
                "managed_simulator.clone_for_shards must be a boolean"
            ),
        ]

        for testCase in cases {
            try writeProfile(testCase.body, named: testCase.name, stateRoot: stateRoot)
            XCTAssertThrowsError(try loadProfile(named: testCase.name, stateRoot: stateRoot), testCase.name) { error in
                XCTAssertTrue(
                    String(describing: error).contains(testCase.expected),
                    "\(testCase.name): \(error)"
                )
            }
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
