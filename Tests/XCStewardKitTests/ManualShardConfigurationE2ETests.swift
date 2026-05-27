// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest

final class ManualShardConfigurationE2ETests: XCTestCase {
    func testManualShardsReceiveDestinationTimeout() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShards)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            [destination]
            timeout = 20
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let toolLog = try String(contentsOf: fakeTools.log)
        let enumerateLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("-enumerate-tests") }))
        XCTAssertTrue(enumerateLine.contains("-destination-timeout 20"))
        let shardLines = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        for line in shardLines {
            XCTAssertTrue(line.contains("-destination-timeout 20"))
        }
    }

    func testManualShardsFilterEnumeratedTestsWithSkipTesting() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShards)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--skip-testing", "DemoTests/FooTests",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        let jobID = try XCTUnwrap(json["job_id"] as? String)
        let toolLog = try String(contentsOf: fakeTools.log)
        let shardLines = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        XCTAssertFalse(shardLines.contains { $0.contains("-only-testing:DemoTests/FooTests") })
        XCTAssertTrue(shardLines.contains { $0.contains("-only-testing:DemoTests/BarTests/testC") })
        XCTAssertTrue(shardLines.contains { $0.contains("-only-testing:DemoTests/BarTests/testD") })
        for line in shardLines {
            XCTAssertTrue(line.contains("-skip-testing:DemoTests/FooTests"))
        }

        let shards = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/shards.json"))) as? [[String: Any]])
        let shardOnlyTesting = Set(shards.flatMap { ($0["only_testing"] as? [String]) ?? [] })
        XCTAssertEqual(shardOnlyTesting, Set(["DemoTests/BarTests/testC", "DemoTests/BarTests/testD"]))
    }

    func testManualShardsPassTestConfigurationFiltersToEnumerationAndShardRuns() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShards)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--only-test-configuration", "Smoke",
                "--skip-test-configuration", "Flaky",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let toolLog = try String(contentsOf: fakeTools.log)
        let enumerateLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("-enumerate-tests") }))
        XCTAssertTrue(enumerateLine.contains("-only-test-configuration Smoke"))
        XCTAssertTrue(enumerateLine.contains("-skip-test-configuration Flaky"))
        let shardLines = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        for line in shardLines {
            XCTAssertTrue(line.contains("-only-test-configuration Smoke"))
            XCTAssertTrue(line.contains("-skip-test-configuration Flaky"))
        }
    }

    func testManualShardsReceiveCodeCoverageSetting() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShards)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            [coverage]
            enabled = false
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let toolLog = try String(contentsOf: fakeTools.log)
        let buildLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("build-for-testing") }))
        XCTAssertTrue(buildLine.contains("-enableCodeCoverage NO"))
        let shardLines = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        for line in shardLines {
            XCTAssertTrue(line.contains("-enableCodeCoverage NO"))
        }
    }

    func testManualShardsReceiveResultStreamPaths() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShards)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            [result_stream]
            enabled = true
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        let jobID = try XCTUnwrap(json["job_id"] as? String)
        let shard0Stream = stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/shards/shard-000/result-stream.json")
        let shard1Stream = stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/shards/shard-001/result-stream.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shard0Stream.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shard1Stream.path))

        let toolLog = try String(contentsOf: fakeTools.log)
        let shardLines = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        let shardCommandLog = shardLines.joined(separator: "\n")
        XCTAssertEqual(shardLines.count, 2)
        XCTAssertTrue(shardLines.contains { $0.contains("-resultStreamPath \(shard0Stream.path)") }, shardCommandLog)
        XCTAssertTrue(shardLines.contains { $0.contains("-resultStreamPath \(shard1Stream.path)") }, shardCommandLog)

        let shards = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/shards.json"))) as? [[String: Any]])
        let streamPaths = Set(shards.compactMap { $0["result_stream"] as? String })
        XCTAssertEqual(streamPaths, Set([shard0Stream.path, shard1Stream.path]))
    }

    func testManualShardsReceiveResultBundleVersion() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShards)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            [result_bundle]
            version = 2
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let toolLog = try String(contentsOf: fakeTools.log)
        let shardLines = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        for line in shardLines {
            XCTAssertTrue(line.contains("-resultBundleVersion 2"))
        }
    }

    func testXCTestRetriesCanRunUntilFailure() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShards)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            [test_retries]
            enabled = true
            iterations = 4
            retry_tests_on_failure = false
            run_tests_until_failure = true
            relaunch_between_iterations = false
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let toolLog = try String(contentsOf: fakeTools.log)
        let shardLines = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        for line in shardLines {
            XCTAssertTrue(line.contains("-test-iterations 4"))
            XCTAssertTrue(line.contains("-run-tests-until-failure"))
            XCTAssertTrue(line.contains("-test-repetition-relaunch-enabled NO"))
            XCTAssertFalse(line.contains("-retry-tests-on-failure"))
        }
    }

    func testManualShardsReceiveConfiguredXCTestDiagnosticsCollection() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShards)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            [test_diagnostics]
            collect = "never"
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let toolLog = try String(contentsOf: fakeTools.log)
        let shardLines = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        for line in shardLines {
            XCTAssertTrue(line.contains("-collect-test-diagnostics never"))
        }
    }
}
