import Foundation
import XCTest

final class LiveXcodeManagedParallelSmokeTests: XCTestCase {
    func testLiveXcodeManagedParallelSmoke() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE"] == "1" else {
            throw XCTSkip("Set XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 to run the live Xcode-managed parallel smoke test.")
        }
        guard let simulatorID = nonEmpty(environment["XCSTEWARD_LIVE_SIMULATOR_ID"]) else {
            throw XCTSkip("Set XCSTEWARD_LIVE_SIMULATOR_ID to an iOS Simulator UDID before running the live smoke test.")
        }

        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let project = try liveProject(environment: environment, temp: temp)
        let maxWorkers = max(Int(environment["XCSTEWARD_LIVE_MAX_WORKERS"] ?? "") ?? 2, 1)

        try writeLiveProfile(
            stateRoot: stateRoot,
            project: project,
            simulatorID: simulatorID,
            maxWorkers: maxWorkers
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "live-xcode-managed",
                "--wait",
                "--json",
            ],
            environment: [
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": environment["XCSTEWARD_LIVE_FOREIGN_ACTIVITY_POLICY"] ?? "ignore",
            ]
        )

        XCTAssertEqual(result.status, 0, "stdout: \(result.stdout)\nstderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        let jobID = try XCTUnwrap(json["job_id"] as? String)

        let counts = try XCTUnwrap(json["counts"] as? [String: Any])
        let testsRun = try XCTUnwrap(counts["testsRun"] as? Int)
        XCTAssertGreaterThanOrEqual(testsRun, project.minimumExpectedTests)

        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let xcresult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: xcresult))

        let runMetadataURL = stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json")
        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: runMetadataURL)) as? [String: Any])
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        let parallelMetadata = try XCTUnwrap(profileMetadata["parallel"] as? [String: Any])
        XCTAssertEqual(parallelMetadata["mode"] as? String, "xcode-managed")
        XCTAssertEqual(parallelMetadata["maxWorkers"] as? Int, maxWorkers)
        XCTAssertEqual(parallelMetadata["exactWorkers"] as? Bool, true)
    }

    private func liveProject(environment: [String: String], temp: URL) throws -> LiveSmokeProject {
        if let repoRoot = nonEmpty(environment["XCSTEWARD_LIVE_REPO_ROOT"]) {
            guard let scheme = nonEmpty(environment["XCSTEWARD_LIVE_SCHEME"]) else {
                throw XCTSkip("Set XCSTEWARD_LIVE_SCHEME when XCSTEWARD_LIVE_REPO_ROOT points at an existing project.")
            }
            return LiveSmokeProject(
                repoRoot: URL(fileURLWithPath: repoRoot),
                scheme: scheme,
                projectPath: nonEmpty(environment["XCSTEWARD_LIVE_PROJECT_PATH"]),
                workspacePath: nonEmpty(environment["XCSTEWARD_LIVE_WORKSPACE_PATH"]),
                minimumExpectedTests: 1
            )
        }

        let repoRoot = temp.appendingPathComponent("LiveSmokePackage")
        try createGeneratedLiveSmokePackage(at: repoRoot)
        return LiveSmokeProject(
            repoRoot: repoRoot,
            scheme: "XCStewardLiveSmoke",
            projectPath: nil,
            workspacePath: nil,
            minimumExpectedTests: 4
        )
    }

    private func writeLiveProfile(
        stateRoot: URL,
        project: LiveSmokeProject,
        simulatorID: String,
        maxWorkers: Int
    ) throws {
        var lines = [
            "repo_root = \"\(project.repoRoot.path)\"",
            "scheme = \"\(project.scheme)\"",
            "default_simulator_id = \"\(simulatorID)\"",
        ]
        if let projectPath = project.projectPath {
            lines.append("project_path = \"\(projectPath)\"")
        }
        if let workspacePath = project.workspacePath {
            lines.append("workspace_path = \"\(workspacePath)\"")
        }
        lines.append(
            """

            [parallel]
            mode = "xcode-managed"
            max_workers = \(maxWorkers)
            exact_workers = true

            [timeouts]
            boot = 120
            build = 600
            test = 600

            [destination]
            timeout = 120
            """
        )
        try writeText(lines.joined(separator: "\n"), to: stateRoot.appendingPathComponent("projects/live-xcode-managed.toml"))
    }

    private func createGeneratedLiveSmokePackage(at repoRoot: URL) throws {
        try writeText(
            """
            // swift-tools-version: 5.9
            import PackageDescription

            let package = Package(
                name: "XCStewardLiveSmoke",
                platforms: [.iOS(.v16)],
                products: [
                    .library(name: "XCStewardLiveSmoke", targets: ["XCStewardLiveSmoke"]),
                ],
                targets: [
                    .target(name: "XCStewardLiveSmoke"),
                    .testTarget(name: "XCStewardLiveSmokeTests", dependencies: ["XCStewardLiveSmoke"]),
                ]
            )
            """,
            to: repoRoot.appendingPathComponent("Package.swift")
        )
        try writeText(
            """
            public func stewardLiveSmokeValue() -> Int {
                42
            }
            """,
            to: repoRoot.appendingPathComponent("Sources/XCStewardLiveSmoke/Smoke.swift")
        )
        try writeText(
            """
            import XCTest
            @testable import XCStewardLiveSmoke

            final class ParallelSmokeATests: XCTestCase {
                func testA() {
                    Thread.sleep(forTimeInterval: 0.5)
                    XCTAssertEqual(stewardLiveSmokeValue(), 42)
                }
            }

            final class ParallelSmokeBTests: XCTestCase {
                func testB() {
                    Thread.sleep(forTimeInterval: 0.5)
                    XCTAssertEqual(stewardLiveSmokeValue(), 42)
                }
            }

            final class ParallelSmokeCTests: XCTestCase {
                func testC() {
                    Thread.sleep(forTimeInterval: 0.5)
                    XCTAssertEqual(stewardLiveSmokeValue(), 42)
                }
            }

            final class ParallelSmokeDTests: XCTestCase {
                func testD() {
                    Thread.sleep(forTimeInterval: 0.5)
                    XCTAssertEqual(stewardLiveSmokeValue(), 42)
                }
            }
            """,
            to: repoRoot.appendingPathComponent("Tests/XCStewardLiveSmokeTests/ParallelSmokeTests.swift")
        )
    }
}

private struct LiveSmokeProject {
    var repoRoot: URL
    var scheme: String
    var projectPath: String?
    var workspacePath: String?
    var minimumExpectedTests: Int
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
