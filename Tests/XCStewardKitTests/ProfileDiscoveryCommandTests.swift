// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest

final class ProfileDiscoveryCommandTests: XCTestCase {
    func testProjectsJSONListsValidAndInvalidProfiles() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )
        try writeText(
            """
            repo_root = "\(repoRoot.path)"
            """,
            to: stateRoot.appendingPathComponent("projects/broken.toml")
        )

        let result = try runCLI(arguments: ["projects", "--state-root", stateRoot.path, "--json"])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
        let document = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(document["schema_version"] as? Int, 1)
        XCTAssertEqual(document["state_root"] as? String, stateRoot.path)
        let projects = try XCTUnwrap(document["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.count, 2)

        let broken = try XCTUnwrap(projects.first { $0["name"] as? String == "broken" })
        XCTAssertEqual(broken["load_status"] as? String, "invalid")
        XCTAssertEqual(broken["error_code"] as? String, "invalid_configuration")

        let demo = try XCTUnwrap(projects.first { $0["name"] as? String == "demo" })
        XCTAssertEqual(demo["load_status"] as? String, "valid")
        XCTAssertEqual(demo["repo_root"] as? String, repoRoot.path)
        XCTAssertEqual(demo["project_path"] as? String, "App.xcodeproj")
        XCTAssertEqual(demo["scheme"] as? String, "Demo")
    }

    func testProfileShowJSONReturnsMaterializedProfile() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let result = try runCLI(arguments: ["profile", "--state-root", stateRoot.path, "show", "demo", "--json"])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
        let document = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(document["schema_version"] as? Int, 1)
        XCTAssertEqual(document["path"] as? String, stateRoot.appendingPathComponent("projects/demo.toml").path)
        let profile = try XCTUnwrap(document["profile"] as? [String: Any])
        XCTAssertEqual(profile["name"] as? String, "demo")
        XCTAssertEqual(profile["repo_root"] as? String, repoRoot.path)
        XCTAssertEqual(profile["project_path"] as? String, "App.xcodeproj")
        XCTAssertEqual(profile["scheme"] as? String, "Demo")
        XCTAssertEqual(profile["default_simulator_id"] as? String, "SIM-123")
    }

    func testProfileInitDetectCreatesProfile() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("DemoRepo")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent("DemoApp.xcodeproj"),
            withIntermediateDirectories: true
        )
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)

        let result = try runCLI(
            arguments: [
                "profile",
                "--state-root", stateRoot.path,
                "init",
                "--repo-root", repoRoot.path,
                "--name", "demo",
                "--detect",
                "--scheme", "Demo",
                "--simulator-id", "SIM-123",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
        let profileURL = stateRoot.appendingPathComponent("projects/demo.toml")
        let profileText = try String(contentsOf: profileURL)
        XCTAssertTrue(profileText.contains("repo_root = \"\(repoRoot.path)\""))
        XCTAssertTrue(profileText.contains("project_path = \"DemoApp.xcodeproj\""))
        XCTAssertTrue(profileText.contains("scheme = \"Demo\""))
        XCTAssertTrue(profileText.contains("default_simulator_id = \"SIM-123\""))

        let document = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(document["schema_version"] as? Int, 1)
        XCTAssertEqual(document["profile_path"] as? String, profileURL.path)
        XCTAssertEqual(document["created"] as? Bool, true)
        XCTAssertEqual(document["warnings"] as? [String], [])
        XCTAssertEqual(document["next_commands"] as? [String], [
            "xcsteward profile show demo --json",
            "xcsteward doctor --project demo --json --progress",
            "xcsteward submit --project demo --wait --json --progress",
        ])
        let profile = try XCTUnwrap(document["profile"] as? [String: Any])
        XCTAssertEqual(profile["name"] as? String, "demo")
        XCTAssertEqual(profile["project_path"] as? String, "DemoApp.xcodeproj")
        XCTAssertEqual(profile["scheme"] as? String, "Demo")
        XCTAssertEqual(profile["default_simulator_id"] as? String, "SIM-123")
    }

    func testProfileInitDetectDefaultsRepoRootToCurrentDirectory() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("DemoRepo")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent("DemoApp.xcodeproj"),
            withIntermediateDirectories: true
        )
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)

        let result = try runCLI(
            arguments: [
                "profile",
                "--state-root", stateRoot.path,
                "init",
                "--detect",
                "--scheme", "Demo",
                "--json",
            ],
            environment: fakeTools.env,
            currentDirectoryURL: repoRoot
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
        let profileURL = stateRoot.appendingPathComponent("projects/DemoRepo.toml")
        let profileText = try String(contentsOf: profileURL)
        XCTAssertTrue(profileText.contains("repo_root = \"\(repoRoot.path)\""))
        XCTAssertTrue(profileText.contains("project_path = \"DemoApp.xcodeproj\""))
        XCTAssertTrue(profileText.contains("scheme = \"Demo\""))

        let document = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(document["profile_path"] as? String, profileURL.path)
        XCTAssertEqual(document["warnings"] as? [String], [
            "No simulator assignment was written; add default_simulator_id or managed_simulator settings before running submit.",
        ])
        XCTAssertEqual(document["next_commands"] as? [String], [
            "xcsteward profile show DemoRepo --json",
            "xcsteward doctor --project DemoRepo --json --progress",
            "xcsteward submit --project DemoRepo --simulator-id <SIMULATOR-UDID> --wait --json --progress",
        ])
        let profile = try XCTUnwrap(document["profile"] as? [String: Any])
        XCTAssertEqual(profile["name"] as? String, "DemoRepo")
        XCTAssertEqual(profile["repo_root"] as? String, repoRoot.path)
        XCTAssertEqual(profile["project_path"] as? String, "DemoApp.xcodeproj")
        XCTAssertEqual(profile["scheme"] as? String, "Demo")
    }
}
