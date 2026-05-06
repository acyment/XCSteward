import Foundation
import XCTest
@testable import XCStewardKit

final class EndToEndCommandTests: XCTestCase {
    func testRootHelpPrintsUsageWithoutCreatingState() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(
            arguments: [
                "--state-root", stateRoot.path,
                "--help",
            ]
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Usage:"))
        XCTAssertTrue(result.stdout.contains("xcsteward [--state-root <path>] <command> [options]"))
        XCTAssertTrue(result.stdout.contains("submit"))
        XCTAssertEqual(result.stderr, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateRoot.path))
    }

    func testSubmitHelpPrintsCommandUsage() throws {
        let result = try runCLI(arguments: ["submit", "--help"])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("xcsteward [--state-root <path>] submit --project <name> [options]"))
        XCTAssertTrue(result.stdout.contains("--only-testing <identifier>"))
        XCTAssertTrue(result.stdout.contains("--skip-testing <identifier>"))
        XCTAssertTrue(result.stdout.contains("--only-test-configuration <name>"))
        XCTAssertTrue(result.stdout.contains("--skip-test-configuration <name>"))
        XCTAssertTrue(result.stdout.contains("--simulator-id <id>"))
        XCTAssertEqual(result.stderr, "")
    }

    func testSubmitWaitSuccessCreatesArtifactsAndStructuredSummary() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
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
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        let jobID = try XCTUnwrap(json["job_id"] as? String)
        let jobDir = stateRoot.appendingPathComponent("jobs/\(jobID)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("request.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("artifacts/result.xcresult/summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("artifacts/summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("artifacts/run-metadata.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("artifacts/xcodebuild-help.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("logs/combined.log").path))
        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: jobDir.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["job_id"] as? String, jobID)
        XCTAssertEqual(runMetadata["project"] as? String, "demo")
        XCTAssertEqual(runMetadata["simulator_id"] as? String, "SIM-123")
        XCTAssertTrue((runMetadata["xcode_version"] as? String)?.contains("Xcode 16.4") == true)
        let xcodebuildHelpPath = try XCTUnwrap(runMetadata["xcodebuild_help_path"] as? String)
        let xcodebuildHelp = try String(contentsOfFile: xcodebuildHelpPath)
        XCTAssertTrue(xcodebuildHelp.contains("-parallel-testing-enabled"))
        XCTAssertTrue(xcodebuildHelp.contains("-destination-timeout"))
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        XCTAssertEqual(profileMetadata["scheme"] as? String, "Demo")
        let parallelMetadata = try XCTUnwrap(profileMetadata["parallel"] as? [String: Any])
        XCTAssertEqual(parallelMetadata["mode"] as? String, "xcode-managed")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let junitPath = try XCTUnwrap(artifacts["junit"] as? String)
        let junit = try String(contentsOfFile: junitPath)
        XCTAssertTrue(junit.contains("<testsuite"))
        XCTAssertTrue(junit.contains("tests=\"3\""))
        XCTAssertTrue(junit.contains("failures=\"0\""))
        XCTAssertTrue(junit.contains("errors=\"0\""))
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_JOB_ID=\(jobID)"))
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PROJECT=demo"))
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PHASE=build"))
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PHASE=test"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_JOB_ID=\(jobID)"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PROJECT=demo"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_MODE=xcode-managed"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PHASE=test"))
        XCTAssertTrue(toolLog.contains("env TMPDIR=\(jobDir.appendingPathComponent("tmp/test").path)"))
    }

    func testSubmitWaitSuccessParsesModernXCResultToolSummary() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .modernXCResultToolSummary)
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
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        let counts = try XCTUnwrap(json["counts"] as? [String: Any])
        XCTAssertEqual(counts["testsRun"] as? Int, 2)
        XCTAssertEqual(counts["testsFailed"] as? Int, 0)
        XCTAssertEqual(counts["testsSkipped"] as? Int, 0)
    }

    func testManagedSimulatorParsingUsesUDIDInsteadOfStatusText() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .managedSimulatorStatusLine)
        try createProfile(
            name: "managed",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Publiqueitor Test iPhone 17 Pro"
            device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
            runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "managed",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-123")
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("-destination id=SIM-123"))
        XCTAssertFalse(toolLog.contains("-destination id=Shutdown"))
    }

    func testManagedSimulatorCreateFailureDoesNotUseErrorOutputAsSimulatorID() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .managedSimulatorCreateFailure)
        try createProfile(
            name: "managed",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Broken Test iPhone"
            device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
            runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "managed",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("CoreSimulator failed to create device") == true)
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcrun simctl create Broken Test iPhone"))
        XCTAssertFalse(toolLog.contains("-destination id=CoreSimulator failed to create device"))
    }

    func testManagedSimulatorCreateSuccessRequiresSingleUDIDOutput() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .managedSimulatorCreateNoisySuccess)
        try createProfile(
            name: "managed",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Noisy Test iPhone"
            device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
            runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
            """
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "managed",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertTrue((json["summary_line"] as? String)?.contains("expected a single simulator UDID") == true)
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcrun simctl create Noisy Test iPhone"))
        XCTAssertFalse(toolLog.contains("-destination id=CoreSimulator warning"))
    }

    func testManagedSimulatorResolutionCanBeCanceledWhileSimctlIsRunning() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .managedSimulatorListHangs)
        try createProfile(
            name: "managed",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Managed Hanging iPhone"
            device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
            runtime = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
            """
        )

        let submit = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "managed",
                "--json",
            ],
            environment: fakeTools.env
        )
        XCTAssertEqual(submit.status, 0, "stderr: \(submit.stderr)")
        let submitJSON = try XCTUnwrap(parseJSON(submit.stdout) as? [String: Any])
        let jobID = try XCTUnwrap(submitJSON["job_id"] as? String)

        let listStarted = try waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: fakeTools.root.appendingPathComponent("managed-list-started").path)
        }
        XCTAssertTrue(listStarted)

        let cancel = try runCLI(
            arguments: [
                "cancel",
                "--state-root", stateRoot.path,
                jobID,
                "--json",
            ],
            environment: fakeTools.env
        )
        XCTAssertEqual(cancel.status, 0, "stderr: \(cancel.stderr)")

        let canceled = try waitUntil(timeout: 5) {
            let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
            let statusJSON = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
            return (statusJSON["state"] as? String) == "canceled"
        }
        XCTAssertTrue(canceled)
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("managed simctl list received SIGTERM"))
        XCTAssertFalse(toolLog.contains("xcrun simctl create Managed Hanging iPhone"))
    }

    func testSubmitSimulatorOverrideWinsOverProfileDefault() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
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

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--simulator-id", "SIM-OVERRIDE",
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-OVERRIDE")
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("-destination id=SIM-OVERRIDE"))
    }

    func testTestWithoutBuildingDoesNotLeakTestPlanFlag() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .xctestrunRejectsTestPlan)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            default_test_plan = "Stable"
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
        XCTAssertEqual(json["result_class"] as? String, "success")
        let toolLog = try String(contentsOf: fakeTools.log)
        let buildLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("build-for-testing") }))
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(buildLine.contains("-testPlan Stable"))
        XCTAssertFalse(buildLine.contains("-parallel-testing-enabled"))
        XCTAssertFalse(buildLine.contains("-maximum-parallel-testing-workers"))
        XCTAssertFalse(testLine.contains("-testPlan Stable"))
        XCTAssertTrue(testLine.contains("-parallel-testing-enabled NO"))
        XCTAssertTrue(testLine.contains("-maximum-parallel-testing-workers 1"))
        XCTAssertFalse(testLine.contains("-parallel-testing-worker-count"))
        XCTAssertTrue(testLine.contains("-test-timeouts-enabled YES"))
        XCTAssertTrue(testLine.contains("-default-test-execution-time-allowance 120"))
        XCTAssertTrue(testLine.contains("-maximum-test-execution-time-allowance 600"))
    }

    func testSerialParallelModeKeepsSingleWorkerFlags() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            mode = "serial"
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
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(testLine.contains("-parallel-testing-enabled NO"))
        XCTAssertTrue(testLine.contains("-maximum-parallel-testing-workers 1"))
        XCTAssertFalse(testLine.contains("-parallel-testing-worker-count"))
    }

    func testXcodeManagedParallelModeUsesConfiguredMaximumWorkers() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            max_workers = 2
            exact_workers = false
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
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(testLine.contains("-parallel-testing-enabled YES"))
        XCTAssertTrue(testLine.contains("-maximum-parallel-testing-workers 2"))
        XCTAssertFalse(testLine.contains("-parallel-testing-worker-count"))
    }

    func testXcodeManagedParallelModeCanUseExactWorkerCount() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            max_workers = 2
            exact_workers = true
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
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(testLine.contains("-parallel-testing-enabled YES"))
        XCTAssertTrue(testLine.contains("-parallel-testing-worker-count 2"))
        XCTAssertFalse(testLine.contains("-maximum-parallel-testing-workers"))
    }

    func testXCTestTimeoutAllowancesCanBeConfiguredAndDisabled() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_timeouts]
            enabled = false
            default_execution_time_allowance = 45
            maximum_execution_time_allowance = 120
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
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(testLine.contains("-test-timeouts-enabled NO"))
        XCTAssertFalse(testLine.contains("-default-test-execution-time-allowance"))
        XCTAssertFalse(testLine.contains("-maximum-test-execution-time-allowance"))
    }

    func testDestinationTimeoutIsPassedToBuildAndTest() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [destination]
            timeout = 45
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
        let toolLog = try String(contentsOf: fakeTools.log)
        let buildLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("build-for-testing") }))
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(buildLine.contains("-destination-timeout 45"))
        XCTAssertTrue(testLine.contains("-destination-timeout 45"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json"))) as? [String: Any])
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        let destinationMetadata = try XCTUnwrap(profileMetadata["destination"] as? [String: Any])
        XCTAssertEqual(destinationMetadata["timeout"] as? Int, 45)
    }

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

    func testSkipTestingIsPassedToXcodeManagedTestRun() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
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
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(testLine.contains("-skip-testing:DemoTests/FooTests"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json"))) as? [String: Any])
        let requestMetadata = try XCTUnwrap(runMetadata["request"] as? [String: Any])
        XCTAssertEqual(requestMetadata["skip_testing"] as? [String], ["DemoTests/FooTests"])
    }

    func testTestConfigurationFiltersArePassedToXcodeManagedTestRun() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
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
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        let jobID = try XCTUnwrap(json["job_id"] as? String)
        let toolLog = try String(contentsOf: fakeTools.log)
        let buildLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("build-for-testing") }))
        XCTAssertFalse(buildLine.contains("-only-test-configuration"))
        XCTAssertFalse(buildLine.contains("-skip-test-configuration"))
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(testLine.contains("-only-test-configuration Smoke"))
        XCTAssertTrue(testLine.contains("-skip-test-configuration Flaky"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json"))) as? [String: Any])
        let requestMetadata = try XCTUnwrap(runMetadata["request"] as? [String: Any])
        XCTAssertEqual(requestMetadata["only_test_configurations"] as? [String], ["Smoke"])
        XCTAssertEqual(requestMetadata["skip_test_configurations"] as? [String], ["Flaky"])
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

    func testCodeCoverageCanBeConfiguredForBuildAndTest() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [coverage]
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
        let toolLog = try String(contentsOf: fakeTools.log)
        let buildLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("build-for-testing") }))
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(buildLine.contains("-enableCodeCoverage YES"))
        XCTAssertTrue(testLine.contains("-enableCodeCoverage YES"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json"))) as? [String: Any])
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        let coverageMetadata = try XCTUnwrap(profileMetadata["coverage"] as? [String: Any])
        XCTAssertEqual(coverageMetadata["enabled"] as? Bool, true)
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

    func testResultStreamCanBeConfiguredForXcodeManagedTestRun() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
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
        let resultStream = stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/result-stream.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultStream.path))
        let toolLog = try String(contentsOf: fakeTools.log)
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(testLine.contains("-resultStreamPath \(resultStream.path)"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_stream_path"] as? String, resultStream.path)
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        let resultStreamMetadata = try XCTUnwrap(profileMetadata["result_stream"] as? [String: Any])
        XCTAssertEqual(resultStreamMetadata["enabled"] as? Bool, true)
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
        XCTAssertEqual(shardLines.count, 2)
        XCTAssertTrue(shardLines.contains { $0.contains("-resultStreamPath \(shard0Stream.path)") })
        XCTAssertTrue(shardLines.contains { $0.contains("-resultStreamPath \(shard1Stream.path)") })

        let shards = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/shards.json"))) as? [[String: Any]])
        let streamPaths = Set(shards.compactMap { $0["result_stream"] as? String })
        XCTAssertEqual(streamPaths, Set([shard0Stream.path, shard1Stream.path]))
    }

    func testResultBundleVersionCanBeConfiguredForXcodeManagedTestRun() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [result_bundle]
            version = 3
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
        let toolLog = try String(contentsOf: fakeTools.log)
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(testLine.contains("-resultBundleVersion 3"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json"))) as? [String: Any])
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        let resultBundleMetadata = try XCTUnwrap(profileMetadata["result_bundle"] as? [String: Any])
        XCTAssertEqual(resultBundleMetadata["version"] as? Int, 3)
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

    func testXCTestRetriesCanUseRetryOnFailure() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_retries]
            enabled = true
            iterations = 3
            retry_tests_on_failure = true
            relaunch_between_iterations = true
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
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(testLine.contains("-test-iterations 3"))
        XCTAssertTrue(testLine.contains("-retry-tests-on-failure"))
        XCTAssertTrue(testLine.contains("-test-repetition-relaunch-enabled YES"))
        XCTAssertFalse(testLine.contains("-run-tests-until-failure"))
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

    func testXCTestDiagnosticsCollectionCanBeConfigured() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_diagnostics]
            collect = "on-failure"
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
        let toolLog = try String(contentsOf: fakeTools.log)
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(testLine.contains("-collect-test-diagnostics on-failure"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json"))) as? [String: Any])
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        let diagnosticsMetadata = try XCTUnwrap(profileMetadata["xctest_diagnostics"] as? [String: Any])
        XCTAssertEqual(diagnosticsMetadata["collect"] as? String, "on-failure")
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

    func testConfiguredPortRangeIsExposedToXcodeManagedTestRunner() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [ports]
            base = 51000
            count = 4
            stride = 10
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
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PORT_RANGE_INDEX=0"))
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PORT_RANGE_START=51000"))
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PORT_RANGE_END=51003"))
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PORT_RANGE_COUNT=4"))
        XCTAssertTrue(toolLog.contains("env XCSTEWARD_PORT_RANGE=51000-51003"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PORT_RANGE_START=51000"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PORT_RANGE=51000-51003"))
    }

    func testConfiguredPrivacyPermissionsAreAppliedBeforeXcodeManagedTestRun() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [privacy]
            reset = ["all"]
            grant = ["photos:com.example.Demo", "location:com.example.Demo"]
            revoke = ["microphone:com.example.Demo"]
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
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcrun simctl privacy SIM-123 reset all"))
        XCTAssertTrue(toolLog.contains("xcrun simctl privacy SIM-123 grant photos com.example.Demo"))
        XCTAssertTrue(toolLog.contains("xcrun simctl privacy SIM-123 grant location com.example.Demo"))
        XCTAssertTrue(toolLog.contains("xcrun simctl privacy SIM-123 revoke microphone com.example.Demo"))
        let combinedLog = try String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/logs/combined.log"))
        XCTAssertTrue(combinedLog.contains("Configured simulator privacy for SIM-123: grant photos com.example.Demo"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json"))) as? [String: Any])
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        let privacyMetadata = try XCTUnwrap(profileMetadata["privacy"] as? [String: Any])
        let permissions = try XCTUnwrap(privacyMetadata["permissions"] as? [[String: Any]])
        XCTAssertEqual(permissions.count, 4)
    }

    func testBuildForTestingCanMaterializeTestProductsArtifact() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_products]
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
        let jobDir = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let testProducts = jobDir.appendingPathComponent("artifacts/test-products.xctestproducts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: testProducts.appendingPathComponent("manifest.json").path))
        let toolLog = try String(contentsOf: fakeTools.log)
        let buildLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("build-for-testing") }))
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(buildLine.contains("-testProductsPath \(testProducts.path)"))
        XCTAssertTrue(testLine.contains("-xctestrun"))
        XCTAssertFalse(testLine.contains("-testProductsPath"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: jobDir.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["test_products_path"] as? String, testProducts.path)
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        let testProductsMetadata = try XCTUnwrap(profileMetadata["test_products"] as? [String: Any])
        XCTAssertEqual(testProductsMetadata["enabled"] as? Bool, true)
    }

    func testTestProductsCanBeUsedForTestWithoutBuilding() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_products]
            enabled = true
            use_for_testing = true
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
        let jobDir = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let testProducts = jobDir.appendingPathComponent("artifacts/test-products.xctestproducts")
        let toolLog = try String(contentsOf: fakeTools.log)
        let buildLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("build-for-testing") }))
        let testLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("test-without-building") }))
        XCTAssertTrue(buildLine.contains("-testProductsPath \(testProducts.path)"))
        XCTAssertTrue(testLine.contains("-testProductsPath \(testProducts.path)"))
        XCTAssertFalse(testLine.contains("-xctestrun"))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: jobDir.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["test_products_path"] as? String, testProducts.path)
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        let testProductsMetadata = try XCTUnwrap(profileMetadata["test_products"] as? [String: Any])
        XCTAssertEqual(testProductsMetadata["enabled"] as? Bool, true)
        XCTAssertEqual(testProductsMetadata["use_for_testing"] as? Bool, true)
    }

    func testManualShardsEnumeratesTestsAndRunsShardResultBundles() throws {
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
            [ports]
            base = 52000
            count = 4
            stride = 10
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
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        XCTAssertEqual(json["summary_line"] as? String, "Manual shards succeeded (2 shards)")
        let counts = try XCTUnwrap(json["counts"] as? [String: Any])
        XCTAssertEqual(counts["testsRun"] as? Int, 4)
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let mergedXCResult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(mergedXCResult)/summary.json"))
        let diagnostics = try loadManualRunDiagnostics(from: artifacts)
        XCTAssertEqual(diagnostics.summary["result_class"] as? String, "success")
        XCTAssertEqual(diagnostics.summary["shard_count"] as? Int, 2)
        XCTAssertEqual(diagnostics.summary["retry_count"] as? Int, 0)
        XCTAssertEqual(diagnostics.summary["merged_result_bundle"] as? String, mergedXCResult)
        let junitPath = try XCTUnwrap(artifacts["junit"] as? String)
        let junit = try String(contentsOfFile: junitPath)
        XCTAssertTrue(junit.contains("tests=\"4\""))
        XCTAssertTrue(junit.contains("failures=\"0\""))
        XCTAssertTrue(junit.contains("DemoTests.FooTests"))
        XCTAssertTrue(junit.contains("name=\"testA\""))
        let jobID = try XCTUnwrap(json["job_id"] as? String)
        let jobDir = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_JOB_ID=\(jobID)"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PROJECT=demo"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_MODE=manual-shards"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PHASE=enumerate-tests"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PHASE=manual-shard"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_SHARD_ID=shard-000"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_SHARD_ID=shard-001"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_SHARD_INDEX=0"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_SHARD_INDEX=1"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_TOTAL_SHARDS=2"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PORT_RANGE_INDEX=0"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PORT_RANGE_INDEX=1"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PORT_RANGE=52000-52003"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PORT_RANGE=52010-52013"))
        XCTAssertTrue(toolLog.contains("env TMPDIR=\(jobDir.appendingPathComponent("artifacts/shards/shard-000/tmp").path)"))
        XCTAssertTrue(toolLog.contains("env TMPDIR=\(jobDir.appendingPathComponent("artifacts/shards/shard-001/tmp").path)"))
        let shardsManifest = try XCTUnwrap(diagnostics.summary["shards_manifest"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shardsManifest))
        let reports = diagnostics.shards
        XCTAssertEqual(reports.count, 2)
        for report in reports {
            let resultBundle = try XCTUnwrap(report["result_bundle"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(resultBundle)/summary.json"))
            let onlyTesting = try XCTUnwrap(report["only_testing"] as? [String])
            XCTAssertEqual(onlyTesting.count, 2)
        }

        let testLines = toolLog.split(separator: "\n").filter { $0.contains("test-without-building") }
        let enumerateLine = try XCTUnwrap(testLines.first(where: { $0.contains("-enumerate-tests") }))
        XCTAssertTrue(enumerateLine.contains("-test-enumeration-output-path"))
        let shardLines = testLines.filter { !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        XCTAssertTrue(shardLines.contains { $0.contains("-destination id=SIM-123") })
        XCTAssertTrue(shardLines.contains { $0.contains("-destination id=SIM-456") })
        XCTAssertTrue(toolLog.contains("xcrun xcresulttool merge"))
        XCTAssertTrue(toolLog.contains("--output-path \(mergedXCResult)"))
        for line in shardLines {
            XCTAssertTrue(line.contains("-parallel-testing-enabled NO"))
            XCTAssertTrue(line.contains("-maximum-parallel-testing-workers 1"))
            XCTAssertFalse(line.contains("-parallel-testing-worker-count"))
            XCTAssertTrue(line.contains("-test-timeouts-enabled YES"))
            XCTAssertTrue(line.contains("-default-test-execution-time-allowance 120"))
            XCTAssertTrue(line.contains("-maximum-test-execution-time-allowance 600"))
            XCTAssertTrue(line.contains("-only-testing:"))
        }
    }

    func testManualShardsCanUseTestProductsRuntime() throws {
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
            [test_products]
            enabled = true
            use_for_testing = true
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
        let testProducts = stateRoot
            .appendingPathComponent("jobs/\(jobID)/artifacts/test-products.xctestproducts")
        let toolLog = try String(contentsOf: fakeTools.log)
        let enumerationLine = try XCTUnwrap(toolLog.split(separator: "\n").first(where: { $0.contains("-enumerate-tests") }))
        XCTAssertTrue(enumerationLine.contains("-testProductsPath \(testProducts.path)"))
        XCTAssertFalse(enumerationLine.contains("-xctestrun"))
        let shardLines = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        for line in shardLines {
            XCTAssertTrue(line.contains("-testProductsPath \(testProducts.path)"))
            XCTAssertFalse(line.contains("-xctestrun"))
        }
    }

    func testManualShardsApplyConfiguredPrivacyToEachShardSimulator() throws {
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
            [privacy]
            grant = ["photos:com.example.Demo"]
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
        XCTAssertTrue(toolLog.contains("xcrun simctl privacy SIM-123 grant photos com.example.Demo"))
        XCTAssertTrue(toolLog.contains("xcrun simctl privacy SIM-456 grant photos com.example.Demo"))
    }

    func testManualShardsKeepPerShardBundlesWhenMergeFails() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShardMergeFailure)
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
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["result_class"] as? String, "success")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        XCTAssertTrue(artifacts["xcresult"] == nil || artifacts["xcresult"] is NSNull)
        let diagnostics = try loadManualRunDiagnostics(from: artifacts)
        XCTAssertEqual(diagnostics.summary["result_class"] as? String, "success")
        XCTAssertEqual(diagnostics.summary["shard_count"] as? Int, 2)
        XCTAssertTrue(diagnostics.summary["merged_result_bundle"] == nil || diagnostics.summary["merged_result_bundle"] is NSNull)
        let reports = diagnostics.shards
        XCTAssertEqual(reports.count, 2)
        for report in reports {
            let resultBundle = try XCTUnwrap(report["result_bundle"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(resultBundle)/summary.json"))
        }
        let jobID = try XCTUnwrap(json["job_id"] as? String)
        let combinedLog = try String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/logs/combined.log"))
        XCTAssertTrue(combinedLog.contains("WARNING: Unable to merge shard result bundles"))
    }

    func testManualShardsRequireEnoughConfiguredSimulatorIDs() throws {
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
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("manual-shards requires 2 simulator IDs") == true)
    }

    func testManualShardsCloneManagedSimulatorWhenConfiguredIDsAreInsufficient() throws {
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
            [managed_simulator]
            name = "iPhone 17 Pro"
            device_type = "iPhone 17 Pro"
            runtime = "iOS 18.0"
            clone_for_shards = true
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
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-123")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let reports = try loadManualRunDiagnostics(from: artifacts).shards
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports.contains { ($0["simulator_id"] as? String) == "SIM-123" })
        XCTAssertTrue(reports.contains { ($0["simulator_id"] as? String) == "00000000-0000-0000-0000-000000000456" })

        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl clone SIM-123 iPhone 17 Pro-xcsteward-"))
        XCTAssertTrue(toolLog.contains("xcrun simctl boot 00000000-0000-0000-0000-000000000456"))
        XCTAssertTrue(toolLog.contains("xcrun simctl delete 00000000-0000-0000-0000-000000000456"))
        XCTAssertFalse(toolLog.contains("xcrun simctl delete SIM-123"))
    }

    func testManualShardRetriesBootstrapFailureAndRecordsRetryDiagnostics() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShardBootstrapRetry)
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
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["result_class"] as? String, "success")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let diagnostics = try loadManualRunDiagnostics(from: artifacts)
        XCTAssertEqual(diagnostics.summary["retry_count"] as? Int, 1)
        let aggregateDiagnostics = try XCTUnwrap(diagnostics.summary["simulator_diagnostics"] as? [String])
        XCTAssertEqual(aggregateDiagnostics.count, 1)
        let reports = diagnostics.shards
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports.contains { ($0["attempts"] as? Int) == 2 && ($0["retry_reason"] as? String) == "runner_bootstrap_failure" })
        XCTAssertTrue(reports.contains { ($0["attempts"] as? Int) == 1 })
        let retriedReport = try XCTUnwrap(reports.first { ($0["attempts"] as? Int) == 2 })
        let shardDiagnostics = try XCTUnwrap(retriedReport["simulator_diagnostics"] as? [String])
        XCTAssertEqual(shardDiagnostics, aggregateDiagnostics)
        let diagnoseLog = try String(contentsOfFile: try XCTUnwrap(shardDiagnostics.first))
        XCTAssertTrue(diagnoseLog.contains("command=xcrun simctl diagnose -l"))
        XCTAssertTrue(diagnoseLog.contains("CoreSimulatorDiagnostic"))

        let toolLog = try String(contentsOf: fakeTools.log)
        let testInvocations = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(testInvocations.count, 3)
        XCTAssertTrue(toolLog.contains("xcrun simctl diagnose -l"))
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown"))
        XCTAssertTrue(toolLog.contains("xcrun simctl erase"))

        let jobID = try XCTUnwrap(json["job_id"] as? String)
        let combinedLog = try String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/logs/combined.log"))
        XCTAssertTrue(combinedLog.contains("WARNING: Retrying shard-"))
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertEqual(try store.countRecentInfrastructureFailures(since: 0), 1)
    }

    func testManualShardRetryPreservesFirstAttemptResultBundle() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .manualShardBootstrapRetryWithPartialResult)
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
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["result_class"] as? String, "success")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let diagnostics = try loadManualRunDiagnostics(from: artifacts)
        let retriedReport = try XCTUnwrap(diagnostics.shards.first { ($0["attempts"] as? Int) == 2 })
        let attemptArtifacts = try XCTUnwrap(retriedReport["attempt_artifacts"] as? [[String: Any]])
        XCTAssertEqual(attemptArtifacts.count, 1)
        let attempt = try XCTUnwrap(attemptArtifacts.first)
        XCTAssertEqual(attempt["phase"] as? String, "manual-shard")
        XCTAssertEqual(attempt["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(attempt["retry_reason"] as? String, "runner_bootstrap_failure")

        let firstAttemptBundle = try XCTUnwrap(attempt["result_bundle"] as? String)
        let finalBundle = try XCTUnwrap(retriedReport["result_bundle"] as? String)
        XCTAssertNotEqual(firstAttemptBundle, finalBundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: firstAttemptBundle).appendingPathComponent("summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: finalBundle).appendingPathComponent("summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(attempt["metadata"] as? String)))
    }

    func testManualShardsUseHistoricalTimingsToBalanceFutureRuns() throws {
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

        func runAndLoadShardReports() throws -> [[String: Any]] {
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
            let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
            return try loadManualRunDiagnostics(from: artifacts).shards
        }

        _ = try runAndLoadShardReports()
        let secondReports = try runAndLoadShardReports()
        let groups = secondReports.map { report in
            Set((report["only_testing"] as? [String]) ?? [])
        }
        XCTAssertTrue(groups.contains(Set(["DemoTests/FooTests/testA"])))
        XCTAssertTrue(groups.contains(Set([
            "DemoTests/FooTests/testB",
            "DemoTests/BarTests/testC",
            "DemoTests/BarTests/testD",
        ])))
    }

    func testHybridParallelModeRunsManualShardsWithInnerXcodeManagedWorkers() throws {
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
            mode = "hybrid"
            shard_count = 2
            max_workers = 2
            exact_workers = false
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
        XCTAssertEqual(json["result_class"] as? String, "success")
        XCTAssertEqual(json["summary_line"] as? String, "Hybrid shards succeeded (2 shards)")
        let toolLog = try String(contentsOf: fakeTools.log)
        let shardLines = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        for line in shardLines {
            XCTAssertTrue(line.contains("-parallel-testing-enabled YES"))
            XCTAssertTrue(line.contains("-maximum-parallel-testing-workers 2"))
            XCTAssertFalse(line.contains("-parallel-testing-worker-count"))
        }
    }

    func testInvalidParallelModeFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            mode = "bogus-mode"
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("unsupported parallel.mode") == true)
    }

    func testInvalidParallelWorkerCountFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            max_workers = 0
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("parallel.max_workers must be >= 1") == true)
    }

    func testInvalidPortRangeFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            [ports]
            base = 65530
            count = 8
            stride = 8
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("ports range exceeds 65535") == true)
    }

    func testInvalidPrivacyServiceFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [privacy]
            grant = ["bluetooth:com.example.Demo"]
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("privacy.grant has unsupported service 'bluetooth'") == true)
    }

    func testInvalidPrivacyGrantWithoutBundleFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [privacy]
            grant = ["photos"]
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("privacy.grant entry 'photos' requires a bundle identifier") == true)
    }

    func testInvalidXCTestTimeoutAllowanceFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_timeouts]
            default_execution_time_allowance = 300
            maximum_execution_time_allowance = 120
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("test_timeouts.maximum_execution_time_allowance must be >= default_execution_time_allowance") == true)
    }

    func testInvalidDestinationTimeoutFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [destination]
            timeout = 0
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("destination.timeout must be >= 1") == true)
    }

    func testInvalidCoverageSettingsFailConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [coverage]
            enabled = "yes"
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("coverage.enabled must be a boolean") == true)
    }

    func testInvalidResultStreamSettingsFailConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [result_stream]
            enabled = "yes"
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("result_stream.enabled must be a boolean") == true)
    }

    func testInvalidResultBundleVersionFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [result_bundle]
            version = 0
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("result_bundle.version must be >= 1") == true)
    }

    func testInvalidXCTestRetrySettingsFailConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_retries]
            enabled = true
            iterations = 3
            retry_tests_on_failure = true
            run_tests_until_failure = true
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("test_retries.retry_tests_on_failure and run_tests_until_failure are mutually exclusive") == true)
    }

    func testInvalidXCTestRetryRelaunchWithoutRetriesFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_retries]
            enabled = false
            relaunch_between_iterations = true
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("test_retries.relaunch_between_iterations requires enabled = true") == true)
    }

    func testInvalidXCTestDiagnosticCollectionFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_diagnostics]
            collect = "always"
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("test_diagnostics.collect must be 'on-failure' or 'never'") == true)
    }

    func testInvalidTestProductsRuntimeSettingsFailConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_products]
            enabled = false
            use_for_testing = true
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("test_products.use_for_testing requires enabled = true") == true)
    }

    func testExecutorUsesGeneratedXCTESTRunFileInsteadOfHardcodedFakeName() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .generatedXCTESTRunPath)
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
        XCTAssertEqual(json["result_class"] as? String, "success")
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("Demo_Stable_iphonesimulator18.0-arm64.xctestrun"))
        XCTAssertFalse(toolLog.contains("fake.xctestrun"))
    }

    func testRunnerConfigurationFailureWithXCResultIsNotClassifiedAsTestFailure() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .runnerConfigurationFailureWithXCResult)
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertNotEqual(json["result_class"] as? String, "test_failure")
    }

    func testTestTimeoutIsClassifiedSeparatelyFromRunnerBootstrapFailure() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .testTimeout)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [timeouts]
            boot = 30
            build = 30
            test = 1
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "test_timeout")
        XCTAssertEqual(json["summary_line"] as? String, "Tests timed out")
    }

    func testSuccessfulTestRunWithCorruptXCResultIsArtifactFailure() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .corruptXCResultSuccess)
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "artifact_failure")
        XCTAssertEqual(json["summary_line"] as? String, "Artifacts were missing or invalid")
        XCTAssertNil(json["counts"])
    }

    func testBuildFailureIsClassified() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .buildFailure)
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["result_class"] as? String, "build_failure")
        XCTAssertEqual(json["state"] as? String, "failed")
        let jobID = try XCTUnwrap(json["job_id"] as? String)
        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json"))) as? [String: Any])
        XCTAssertEqual(runMetadata["result_class"] as? String, "build_failure")
        XCTAssertEqual(runMetadata["state"] as? String, "failed")
    }

    func testBootStatusFailureProducesTerminalRunnerBootstrapFailureSummary() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .bootStatusFailure)
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(json["state"] as? String, "failed")
        let jobID = try XCTUnwrap(json["job_id"] as? String)

        let status = try runCLI(
            arguments: [
                "status",
                "--state-root", stateRoot.path,
                jobID,
                "--json",
            ],
            environment: fakeTools.env
        )
        let statusJSON = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
        XCTAssertEqual(statusJSON["state"] as? String, "failed")
    }

    func testExecutorRecoversWhenAlreadyBootedSimulatorFailsBootstatus() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .bootedSimulatorNeedsRecovery)
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
        XCTAssertEqual(json["result_class"] as? String, "success")
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertGreaterThanOrEqual(toolLog.components(separatedBy: "xcrun simctl boot SIM-123").count - 1, 2)
        XCTAssertGreaterThanOrEqual(toolLog.components(separatedBy: "xcrun simctl bootstatus SIM-123 -b").count - 1, 2)
    }

    func testBootstrapRetryUsesTargetedCleanupAndThenSucceeds() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .bootstrapRetry)
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
        XCTAssertEqual(json["result_class"] as? String, "success")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let diagnosticsPath = try XCTUnwrap(artifacts["diagnostics"] as? String)
        let diagnostics = try String(contentsOfFile: diagnosticsPath)
        XCTAssertTrue(diagnostics.contains("command=xcrun simctl diagnose -l"))
        XCTAssertTrue(diagnostics.contains("CoreSimulatorDiagnostic"))
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcrun simctl diagnose -l"))
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl erase SIM-123"))
        XCTAssertFalse(toolLog.contains("shutdown all"))
        XCTAssertFalse(toolLog.contains("erase all"))
    }

    func testBootstrapRetryPreservesFirstAttemptResultBundle() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .bootstrapRetryWithPartialResult)
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
        XCTAssertEqual(json["result_class"] as? String, "success")
        let jobID = try XCTUnwrap(json["job_id"] as? String)
        let jobDir = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let finalBundle = jobDir.appendingPathComponent("artifacts/result.xcresult/summary.json")
        let preservedBundle = jobDir.appendingPathComponent("artifacts/attempts/test-attempt-001/result.xcresult/summary.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalBundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedBundle.path))

        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: jobDir.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any])
        let attempts = try XCTUnwrap(runMetadata["attempts"] as? [[String: Any]])
        XCTAssertEqual(attempts.count, 1)
        let attempt = try XCTUnwrap(attempts.first)
        XCTAssertEqual(attempt["phase"] as? String, "test")
        XCTAssertEqual(attempt["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(attempt["retry_reason"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(attempt["result_bundle"] as? String, jobDir.appendingPathComponent("artifacts/attempts/test-attempt-001/result.xcresult").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(attempt["metadata"] as? String)))
    }

    func testExecutorBootsSimulatorBeforeBuildAndTest() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
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
        XCTAssertTrue(toolLog.contains("xcrun simctl boot SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl bootstatus SIM-123 -b"))
    }

    func testResetPolicyShutdownCleansOnlyResolvedSimulatorAfterJob() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            reset_policy = "shutdown"
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
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertFalse(toolLog.contains("shutdown all"))
        XCTAssertFalse(toolLog.contains("xcrun simctl erase SIM-123"))
    }

    func testResetPolicyEraseCleansAllManualShardSimulatorsAfterJob() throws {
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
            reset_policy = "erase"
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
                "--wait",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl erase SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-456"))
        XCTAssertTrue(toolLog.contains("xcrun simctl erase SIM-456"))
        XCTAssertFalse(toolLog.contains("erase all"))
    }

    func testInvalidResetPolicyFailsConfiguration() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "demo",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            reset_policy = "shutdown-all"
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertTrue((json["summary_line"] as? String)?.contains("unsupported reset_policy") == true)
    }

    func testExecutorWarnsAndContinuesWhenCompetingSimulatorTestProcessIsActive() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .concurrentRunnerContention)
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
        XCTAssertEqual(json["result_class"] as? String, "success")
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcodebuild -project"))
        let jobID = try XCTUnwrap(json["job_id"] as? String)
        let combinedLog = try String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/logs/combined.log"))
        let buildLog = try String(contentsOf: stateRoot.appendingPathComponent("jobs/\(jobID)/logs/build.log"))
        XCTAssertTrue(combinedLog.contains("WARNING: Competing simulator-hosted test activity detected"))
        XCTAssertTrue(buildLog.contains("WARNING: Competing simulator-hosted test activity detected"))
    }

    func testSecondJobQueuesAndCanBeCanceledWhileFirstRuns() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .queuedCancellation)
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

        let firstSubmit = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--json",
            ],
            environment: fakeTools.env
        )
        XCTAssertEqual(firstSubmit.status, 0, "stderr: \(firstSubmit.stderr)")
        let firstJobPersisted = try waitUntil(timeout: 5) {
            let jobs = try runCLI(arguments: ["jobs", "--state-root", stateRoot.path, "--json"], environment: fakeTools.env)
            let parsed = try XCTUnwrap(parseJSON(jobs.stdout) as? [[String: Any]])
            return !parsed.isEmpty
        }
        XCTAssertTrue(firstJobPersisted)
        let firstJobStarted = try waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: fakeTools.root.appendingPathComponent("queued-cancellation-first-started").path)
        }
        XCTAssertTrue(firstJobStarted)

        let second = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--json",
            ],
            environment: fakeTools.env
        )
        XCTAssertEqual(second.status, 0, "stderr: \(second.stderr)")

        var lastJobsOutput = ""
        let queuedObserved = try waitUntil(timeout: 5) {
            let jobs = try runCLI(arguments: ["jobs", "--state-root", stateRoot.path, "--json"], environment: fakeTools.env)
            lastJobsOutput = jobs.stdout
            let parsed = try XCTUnwrap(parseJSON(jobs.stdout) as? [[String: Any]])
            return parsed.contains { ($0["state"] as? String) == "queued" }
        }
        XCTAssertTrue(queuedObserved, "jobs output: \(lastJobsOutput)")
        let queuedJobs = try XCTUnwrap(parseJSON(lastJobsOutput) as? [[String: Any]])
        let secondJobID = try XCTUnwrap(queuedJobs.first(where: { ($0["state"] as? String) == "queued" })?["job_id"] as? String)

        let cancel = try runCLI(
            arguments: [
                "cancel",
                "--state-root", stateRoot.path,
                secondJobID,
                "--json",
            ],
            environment: fakeTools.env
        )
        let cancelJSON = try XCTUnwrap(parseJSON(cancel.stdout) as? [String: Any])
        XCTAssertEqual(cancelJSON["state"] as? String, "canceled")
        try writeText("", to: fakeTools.root.appendingPathComponent("release-queued-cancellation"))

        let jobs = try runCLI(arguments: ["jobs", "--state-root", stateRoot.path, "--json"], environment: fakeTools.env)
        let jobsJSON = try XCTUnwrap(parseJSON(jobs.stdout) as? [[String: Any]])
        let firstJobID = try XCTUnwrap(jobsJSON.first(where: { ($0["job_id"] as? String) != secondJobID })?["job_id"] as? String, "jobs output: \(jobs.stdout)")
        let finished = try waitUntil(timeout: 10) {
            let first = try runCLI(arguments: ["status", "--state-root", stateRoot.path, firstJobID, "--json"], environment: fakeTools.env)
            let second = try runCLI(arguments: ["status", "--state-root", stateRoot.path, secondJobID, "--json"], environment: fakeTools.env)
            let firstJSON = try XCTUnwrap(parseJSON(first.stdout) as? [String: Any])
            let secondJSON = try XCTUnwrap(parseJSON(second.stdout) as? [String: Any])
            return (firstJSON["state"] as? String) == "succeeded" && (secondJSON["state"] as? String) == "canceled"
        }
        XCTAssertTrue(finished)

        let firstStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, firstJobID, "--json"], environment: fakeTools.env)
        let firstStatusJSON = try XCTUnwrap(parseJSON(firstStatus.stdout) as? [String: Any])
        XCTAssertEqual(firstStatusJSON["state"] as? String, "succeeded")
        let secondStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, secondJobID, "--json"], environment: fakeTools.env)
        let secondStatusJSON = try XCTUnwrap(parseJSON(secondStatus.stdout) as? [String: Any])
        XCTAssertEqual(secondStatusJSON["state"] as? String, "canceled")
    }

    func testWorkerRunsDifferentSimulatorJobsConcurrentlyWhenBudgetAllows() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .slowSuccess,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try createProfile(
            name: "demo-a",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-A"
            """
        )
        try createProfile(
            name: "demo-b",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-B"
            """
        )

        let first = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-a", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(first.status, 0, "stderr: \(first.stderr)")
        let firstJSON = try XCTUnwrap(parseJSON(first.stdout) as? [String: Any])
        let firstJobID = try XCTUnwrap(firstJSON["job_id"] as? String)

        let second = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-b", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(second.status, 0, "stderr: \(second.stderr)")
        let secondJSON = try XCTUnwrap(parseJSON(second.stdout) as? [String: Any])
        let secondJobID = try XCTUnwrap(secondJSON["job_id"] as? String)

        let bothBuildsStarted = try waitUntil(timeout: 3) {
            guard FileManager.default.fileExists(atPath: fakeTools.log.path) else {
                return false
            }
            let toolLog = try String(contentsOf: fakeTools.log)
            return toolLog.components(separatedBy: "build-for-testing").count - 1 >= 2
        }
        XCTAssertTrue(bothBuildsStarted)

        let bothTestsStarted = try waitUntil(timeout: 8) {
            let toolLog = try String(contentsOf: fakeTools.log)
            let testStarts = toolLog.split(separator: "\n")
                .filter { $0.contains("event start phase=test") }
            return testStarts.count >= 2
        }
        XCTAssertTrue(bothTestsStarted)

        let bothFinished = try waitUntil(timeout: 15) {
            let firstStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, firstJobID, "--json"], environment: fakeTools.env)
            let secondStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, secondJobID, "--json"], environment: fakeTools.env)
            let firstStatusJSON = try XCTUnwrap(parseJSON(firstStatus.stdout) as? [String: Any])
            let secondStatusJSON = try XCTUnwrap(parseJSON(secondStatus.stdout) as? [String: Any])
            return (firstStatusJSON["state"] as? String) == "succeeded" &&
                (secondStatusJSON["state"] as? String) == "succeeded"
        }
        XCTAssertTrue(bothFinished)

        let toolLogAfterFinish = try String(contentsOf: fakeTools.log)
        let eventLines = toolLogAfterFinish.split(separator: "\n")
            .filter { $0.hasPrefix("event ") }
        let testStartEntries = eventLines.enumerated()
            .filter { $0.element.contains("event start phase=test") }
        let firstTestEndIndex = try XCTUnwrap(
            eventLines.firstIndex { $0.contains("event end phase=test") },
            "At least one test end marker should be present after both jobs finish"
        )
        XCTAssertEqual(testStartEntries.count, 2)
        XCTAssertTrue(testStartEntries.allSatisfy { $0.offset < firstTestEndIndex })
        let startedResultBundles = Set(testStartEntries.compactMap { logField("result", in: $0.element) })
        XCTAssertEqual(startedResultBundles.count, 2)

        let firstStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, firstJobID, "--json"], environment: fakeTools.env)
        let secondStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, secondJobID, "--json"], environment: fakeTools.env)
        let firstStatusJSON = try XCTUnwrap(parseJSON(firstStatus.stdout) as? [String: Any])
        let secondStatusJSON = try XCTUnwrap(parseJSON(secondStatus.stdout) as? [String: Any])
        let firstArtifacts = try XCTUnwrap(firstStatusJSON["artifacts"] as? [String: Any])
        let secondArtifacts = try XCTUnwrap(secondStatusJSON["artifacts"] as? [String: Any])
        let firstXCResult = try XCTUnwrap(firstArtifacts["xcresult"] as? String)
        let secondXCResult = try XCTUnwrap(secondArtifacts["xcresult"] as? String)
        XCTAssertNotEqual(firstXCResult, secondXCResult)
        XCTAssertTrue(startedResultBundles.contains(firstXCResult))
        XCTAssertTrue(startedResultBundles.contains(secondXCResult))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(firstXCResult)/summary.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(secondXCResult)/summary.json"))
    }

    func testWorkerRefillsCapacityWhenOneOfTwoRunningJobsFinishes() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .slowSuccess,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        for (project, simulatorID) in [("demo-a", "SIM-A"), ("demo-b", "SIM-B"), ("demo-c", "SIM-C")] {
            try createProfile(
                name: project,
                stateRoot: stateRoot,
                repoRoot: repoRoot,
                body: """
                project_path = "App.xcodeproj"
                scheme = "Demo"
                default_simulator_id = "\(simulatorID)"
                """
            )
        }

        let jobIDs = try ["demo-a", "demo-b", "demo-c"].map { project in
            let result = try runCLI(
                arguments: ["submit", "--state-root", stateRoot.path, "--project", project, "--json"],
                environment: fakeTools.env
            )
            XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
            let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
            return try XCTUnwrap(json["job_id"] as? String)
        }

        let firstTwoBuildsStarted = try waitUntil(timeout: 3) {
            guard FileManager.default.fileExists(atPath: fakeTools.log.path) else {
                return false
            }
            let events = try fakeToolEvents(at: fakeTools.log)
            return events.filter { $0.contains("event start phase=build") }.count == 2
        }
        XCTAssertTrue(firstTwoBuildsStarted)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try fakeToolEvents(at: fakeTools.log).filter { $0.contains("event start phase=build") }.count, 2)

        let allFinished = try waitUntil(timeout: 30) {
            try jobIDs.allSatisfy { jobID in
                let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
                let json = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
                return (json["state"] as? String) == "succeeded"
            }
        }
        XCTAssertTrue(allFinished)

        let events = try fakeToolEvents(at: fakeTools.log)
        let buildStarts = events.enumerated().filter { $0.element.contains("event start phase=build") }
        let firstBuildEndIndex = try XCTUnwrap(events.firstIndex { $0.contains("event end phase=build") })
        let firstTestEndIndex = try XCTUnwrap(events.firstIndex { $0.contains("event end phase=test") })
        XCTAssertEqual(buildStarts.count, 3)
        XCTAssertEqual(buildStarts.filter { $0.offset < firstBuildEndIndex }.count, 2)
        let thirdBuildStart = try XCTUnwrap(buildStarts.map(\.offset).max())
        XCTAssertGreaterThan(thirdBuildStart, firstTestEndIndex)
    }

    func testWorkerReportsControlledLeaseFailureForConcurrentJobsOnSameSimulator() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .slowSuccess,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try createProfile(
            name: "demo-a",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-SHARED"
            """
        )
        try createProfile(
            name: "demo-b",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-SHARED"
            """
        )

        let first = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-a", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(first.status, 0, "stderr: \(first.stderr)")
        let firstJSON = try XCTUnwrap(parseJSON(first.stdout) as? [String: Any])
        let firstJobID = try XCTUnwrap(firstJSON["job_id"] as? String)

        let second = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-b", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(second.status, 0, "stderr: \(second.stderr)")
        let secondJSON = try XCTUnwrap(parseJSON(second.stdout) as? [String: Any])
        let secondJobID = try XCTUnwrap(secondJSON["job_id"] as? String)

        let bothTerminal = try waitUntil(timeout: 15) {
            let firstStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, firstJobID, "--json"], environment: fakeTools.env)
            let secondStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, secondJobID, "--json"], environment: fakeTools.env)
            let firstStatusJSON = try XCTUnwrap(parseJSON(firstStatus.stdout) as? [String: Any])
            let secondStatusJSON = try XCTUnwrap(parseJSON(secondStatus.stdout) as? [String: Any])
            return (firstStatusJSON["state"] as? String)?.isTerminalJobState == true &&
                (secondStatusJSON["state"] as? String)?.isTerminalJobState == true
        }
        XCTAssertTrue(bothTerminal)

        let firstStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, firstJobID, "--json"], environment: fakeTools.env)
        let secondStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, secondJobID, "--json"], environment: fakeTools.env)
        let summaries = try [
            XCTUnwrap(parseJSON(firstStatus.stdout) as? [String: Any]),
            XCTUnwrap(parseJSON(secondStatus.stdout) as? [String: Any]),
        ]
        let succeeded = summaries.filter { ($0["state"] as? String) == "succeeded" }
        let failed = summaries.filter { ($0["state"] as? String) == "failed" }
        XCTAssertEqual(succeeded.count, 1)
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertTrue((failed.first?["summary_line"] as? String)?.contains("already leased by another XCSteward job") == true)

        let artifacts = try XCTUnwrap(succeeded.first?["artifacts"] as? [String: Any])
        let xcresult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(xcresult)/summary.json"))
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertEqual(toolLog.components(separatedBy: "build-for-testing").count - 1, 1)
        XCTAssertEqual(try fakeToolEvents(at: fakeTools.log).filter { $0.contains("event start phase=test") }.count, 1)
    }

    func testWorkerKeepsParallelMixedOutcomesIsolated() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .parallelMixedOutcomes,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try createProfile(
            name: "demo-success",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-SUCCESS"
            """
        )
        try createProfile(
            name: "demo-artifact",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-ARTIFACT"
            """
        )

        let successSubmit = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-success", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(successSubmit.status, 0, "stderr: \(successSubmit.stderr)")
        let successJSON = try XCTUnwrap(parseJSON(successSubmit.stdout) as? [String: Any])
        let successJobID = try XCTUnwrap(successJSON["job_id"] as? String)

        let artifactSubmit = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-artifact", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(artifactSubmit.status, 0, "stderr: \(artifactSubmit.stderr)")
        let artifactJSON = try XCTUnwrap(parseJSON(artifactSubmit.stdout) as? [String: Any])
        let artifactJobID = try XCTUnwrap(artifactJSON["job_id"] as? String)

        let bothTestsStarted = try waitUntil(timeout: 8) {
            try fakeToolEvents(at: fakeTools.log)
                .filter { $0.contains("event start phase=test") }
                .count == 2
        }
        XCTAssertTrue(bothTestsStarted)

        let bothTerminal = try waitUntil(timeout: 15) {
            let successStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, successJobID, "--json"], environment: fakeTools.env)
            let artifactStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, artifactJobID, "--json"], environment: fakeTools.env)
            let successStatusJSON = try XCTUnwrap(parseJSON(successStatus.stdout) as? [String: Any])
            let artifactStatusJSON = try XCTUnwrap(parseJSON(artifactStatus.stdout) as? [String: Any])
            return (successStatusJSON["state"] as? String)?.isTerminalJobState == true &&
                (artifactStatusJSON["state"] as? String)?.isTerminalJobState == true
        }
        XCTAssertTrue(bothTerminal)

        let successStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, successJobID, "--json"], environment: fakeTools.env)
        let artifactStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, artifactJobID, "--json"], environment: fakeTools.env)
        let successStatusJSON = try XCTUnwrap(parseJSON(successStatus.stdout) as? [String: Any])
        let artifactStatusJSON = try XCTUnwrap(parseJSON(artifactStatus.stdout) as? [String: Any])
        XCTAssertEqual(successStatusJSON["state"] as? String, "succeeded")
        XCTAssertEqual(successStatusJSON["result_class"] as? String, "success")
        XCTAssertEqual(artifactStatusJSON["state"] as? String, "failed")
        XCTAssertEqual(artifactStatusJSON["result_class"] as? String, "artifact_failure")

        let successArtifacts = try XCTUnwrap(successStatusJSON["artifacts"] as? [String: Any])
        let artifactArtifacts = try XCTUnwrap(artifactStatusJSON["artifacts"] as? [String: Any])
        let successXCResult = try XCTUnwrap(successArtifacts["xcresult"] as? String)
        let artifactXCResult = try XCTUnwrap(artifactArtifacts["xcresult"] as? String)
        XCTAssertNotEqual(successXCResult, artifactXCResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(successXCResult)/summary.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(artifactXCResult)/summary.json"))

        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertEqual(try store.countRecentInfrastructureFailures(since: 0), 1)
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }

    func testWorkerCancelOneParallelJobDoesNotStopOtherRunningJob() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .parallelCancellation,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try createProfile(
            name: "demo-keep",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-KEEP"
            """
        )
        try createProfile(
            name: "demo-cancel",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-CANCEL"
            """
        )

        let keepSubmit = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-keep", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(keepSubmit.status, 0, "stderr: \(keepSubmit.stderr)")
        let keepJSON = try XCTUnwrap(parseJSON(keepSubmit.stdout) as? [String: Any])
        let keepJobID = try XCTUnwrap(keepJSON["job_id"] as? String)

        let cancelSubmit = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-cancel", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(cancelSubmit.status, 0, "stderr: \(cancelSubmit.stderr)")
        let cancelJSON = try XCTUnwrap(parseJSON(cancelSubmit.stdout) as? [String: Any])
        let cancelJobID = try XCTUnwrap(cancelJSON["job_id"] as? String)

        let bothTestsStarted = try waitUntil(timeout: 8) {
            try fakeToolEvents(at: fakeTools.log)
                .filter { $0.contains("event start phase=test") }
                .count == 2
        }
        XCTAssertTrue(bothTestsStarted)

        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        let cancelProcessTracked = try waitUntil(timeout: 3) {
            try store.fetchJob(id: cancelJobID)?.processID != nil
        }
        XCTAssertTrue(cancelProcessTracked)

        let cancel = try runCLI(
            arguments: ["cancel", "--state-root", stateRoot.path, cancelJobID, "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(cancel.status, 0, "stderr: \(cancel.stderr)")
        try writeText("", to: fakeTools.root.appendingPathComponent("release-demo-cancel"))

        let terminal = try waitUntil(timeout: 15) {
            let keepStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, keepJobID, "--json"], environment: fakeTools.env)
            let cancelStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, cancelJobID, "--json"], environment: fakeTools.env)
            let keepStatusJSON = try XCTUnwrap(parseJSON(keepStatus.stdout) as? [String: Any])
            let cancelStatusJSON = try XCTUnwrap(parseJSON(cancelStatus.stdout) as? [String: Any])
            return (keepStatusJSON["state"] as? String) == "succeeded" &&
                (cancelStatusJSON["state"] as? String) == "canceled"
        }
        XCTAssertTrue(terminal)

        let keepStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, keepJobID, "--json"], environment: fakeTools.env)
        let cancelStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, cancelJobID, "--json"], environment: fakeTools.env)
        let keepStatusJSON = try XCTUnwrap(parseJSON(keepStatus.stdout) as? [String: Any])
        let cancelStatusJSON = try XCTUnwrap(parseJSON(cancelStatus.stdout) as? [String: Any])
        XCTAssertEqual(keepStatusJSON["result_class"] as? String, "success")
        XCTAssertEqual(cancelStatusJSON["result_class"] as? String, "canceled")
        let keepArtifacts = try XCTUnwrap(keepStatusJSON["artifacts"] as? [String: Any])
        let keepXCResult = try XCTUnwrap(keepArtifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(keepXCResult)/summary.json"))

        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcodebuild observed cancellation project=demo-cancel"))
        XCTAssertFalse(toolLog.contains("xcodebuild observed cancellation project=demo-keep"))
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }

    func testWorkerRunsConcurrentManualShardJobsWithIsolatedArtifactsAndLeases() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .manualShardsConcurrent,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try createProfile(
            name: "demo-a",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-A0"
            allowed_simulator_ids = ["SIM-A1"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            """
        )
        try createProfile(
            name: "demo-b",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-B0"
            allowed_simulator_ids = ["SIM-B1"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            """
        )

        let first = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-a", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(first.status, 0, "stderr: \(first.stderr)")
        let firstJSON = try XCTUnwrap(parseJSON(first.stdout) as? [String: Any])
        let firstJobID = try XCTUnwrap(firstJSON["job_id"] as? String)

        let second = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-b", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(second.status, 0, "stderr: \(second.stderr)")
        let secondJSON = try XCTUnwrap(parseJSON(second.stdout) as? [String: Any])
        let secondJobID = try XCTUnwrap(secondJSON["job_id"] as? String)

        let allShardsStarted = try waitUntil(timeout: 10) {
            try fakeToolEvents(at: fakeTools.log)
                .filter { $0.contains("event start phase=manual-shard") }
                .count == 4
        }
        XCTAssertTrue(allShardsStarted)

        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        let activeLeases = Set(try store.listSimulatorLeases().map(\.simulatorID))
        XCTAssertEqual(activeLeases, Set(["SIM-A0", "SIM-A1", "SIM-B0", "SIM-B1"]))

        let bothFinished = try waitUntil(timeout: 20) {
            let firstStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, firstJobID, "--json"], environment: fakeTools.env)
            let secondStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, secondJobID, "--json"], environment: fakeTools.env)
            let firstStatusJSON = try XCTUnwrap(parseJSON(firstStatus.stdout) as? [String: Any])
            let secondStatusJSON = try XCTUnwrap(parseJSON(secondStatus.stdout) as? [String: Any])
            return (firstStatusJSON["state"] as? String) == "succeeded" &&
                (secondStatusJSON["state"] as? String) == "succeeded"
        }
        XCTAssertTrue(bothFinished)

        let firstStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, firstJobID, "--json"], environment: fakeTools.env)
        let secondStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, secondJobID, "--json"], environment: fakeTools.env)
        let firstStatusJSON = try XCTUnwrap(parseJSON(firstStatus.stdout) as? [String: Any])
        let secondStatusJSON = try XCTUnwrap(parseJSON(secondStatus.stdout) as? [String: Any])
        XCTAssertEqual(firstStatusJSON["result_class"] as? String, "success")
        XCTAssertEqual(secondStatusJSON["result_class"] as? String, "success")
        XCTAssertEqual((firstStatusJSON["counts"] as? [String: Any])?["testsRun"] as? Int, 4)
        XCTAssertEqual((secondStatusJSON["counts"] as? [String: Any])?["testsRun"] as? Int, 4)

        let firstShardsPath = stateRoot.appendingPathComponent("jobs/\(firstJobID)/artifacts/shards.json")
        let secondShardsPath = stateRoot.appendingPathComponent("jobs/\(secondJobID)/artifacts/shards.json")
        let firstSummaryPath = stateRoot.appendingPathComponent("jobs/\(firstJobID)/artifacts/combined-summary.json")
        let secondSummaryPath = stateRoot.appendingPathComponent("jobs/\(secondJobID)/artifacts/combined-summary.json")
        let firstShards = try XCTUnwrap(parseJSON(String(contentsOf: firstShardsPath)) as? [[String: Any]])
        let secondShards = try XCTUnwrap(parseJSON(String(contentsOf: secondShardsPath)) as? [[String: Any]])
        XCTAssertEqual(firstShards.count, 2)
        XCTAssertEqual(secondShards.count, 2)
        XCTAssertEqual(Set(firstShards.compactMap { $0["simulator_id"] as? String }), Set(["SIM-A0", "SIM-A1"]))
        XCTAssertEqual(Set(secondShards.compactMap { $0["simulator_id"] as? String }), Set(["SIM-B0", "SIM-B1"]))

        let firstResultBundles = Set(firstShards.compactMap { $0["result_bundle"] as? String })
        let secondResultBundles = Set(secondShards.compactMap { $0["result_bundle"] as? String })
        XCTAssertEqual(firstResultBundles.count, 2)
        XCTAssertEqual(secondResultBundles.count, 2)
        XCTAssertTrue(firstResultBundles.isDisjoint(with: secondResultBundles))
        XCTAssertTrue(firstResultBundles.allSatisfy { $0.contains("/jobs/\(firstJobID)/") })
        XCTAssertTrue(secondResultBundles.allSatisfy { $0.contains("/jobs/\(secondJobID)/") })

        let firstSummary = try XCTUnwrap(parseJSON(String(contentsOf: firstSummaryPath)) as? [String: Any])
        let secondSummary = try XCTUnwrap(parseJSON(String(contentsOf: secondSummaryPath)) as? [String: Any])
        XCTAssertEqual(firstSummary["shard_count"] as? Int, 2)
        XCTAssertEqual(secondSummary["shard_count"] as? Int, 2)
        XCTAssertEqual(firstSummary["result_class"] as? String, "success")
        XCTAssertEqual(secondSummary["result_class"] as? String, "success")
        XCTAssertNotEqual(firstSummary["shards_manifest"] as? String, secondSummary["shards_manifest"] as? String)
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }

    func testWorkerAppliesDynamicBackpressureWithoutInterruptingRunningJobs() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .dynamicBackpressure,
            extraEnv: [
                "XCSTEWARD_MAX_CONCURRENT_JOBS": "2",
                "XCSTEWARD_SAMPLE_MEMORY_PRESSURE": "1",
            ]
        )
        for (project, simulatorID) in [("demo-a", "SIM-A"), ("demo-b", "SIM-B"), ("demo-c", "SIM-C")] {
            try createProfile(
                name: project,
                stateRoot: stateRoot,
                repoRoot: repoRoot,
                body: """
                project_path = "App.xcodeproj"
                scheme = "Demo"
                default_simulator_id = "\(simulatorID)"
                """
            )
        }

        let jobIDs = try ["demo-a", "demo-b", "demo-c"].map { project in
            let result = try runCLI(
                arguments: ["submit", "--state-root", stateRoot.path, "--project", project, "--json"],
                environment: fakeTools.env
            )
            XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
            let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
            return try XCTUnwrap(json["job_id"] as? String)
        }

        let firstTwoTestsStarted = try waitUntil(timeout: 8) {
            try fakeToolEvents(at: fakeTools.log)
                .filter { $0.contains("event start phase=test") }
                .count == 2
        }
        XCTAssertTrue(firstTwoTestsStarted)

        try writeText("", to: fakeTools.root.appendingPathComponent("constrain-host"))
        let healthConstrained = try waitUntil(timeout: 5) {
            guard FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("host-health.json").path) else {
                return false
            }
            let health = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any])
            return (health["effective_max_jobs"] as? Int) == 1 &&
                ((health["reasons"] as? [String])?.contains("memory_pressure=warning") == true)
        }
        XCTAssertTrue(healthConstrained)

        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(
            try fakeToolEvents(at: fakeTools.log).filter { $0.contains("event start phase=test") }.count,
            2
        )

        let thirdStatusWhileConstrained = try runCLI(
            arguments: ["status", "--state-root", stateRoot.path, jobIDs[2], "--json"],
            environment: fakeTools.env
        )
        let thirdStatusJSON = try XCTUnwrap(parseJSON(thirdStatusWhileConstrained.stdout) as? [String: Any])
        XCTAssertEqual(thirdStatusJSON["state"] as? String, "queued")

        try writeText("", to: fakeTools.root.appendingPathComponent("release-running"))
        let allFinished = try waitUntil(timeout: 20) {
            try jobIDs.allSatisfy { jobID in
                let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
                let json = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
                return (json["state"] as? String) == "succeeded"
            }
        }
        XCTAssertTrue(allFinished)

        let events = try fakeToolEvents(at: fakeTools.log)
        let testStarts = events.enumerated().filter { $0.element.contains("event start phase=test") }
        let testEnds = events.enumerated().filter { $0.element.contains("event end phase=test") }
        XCTAssertEqual(testStarts.count, 3)
        XCTAssertEqual(testEnds.count, 3)
        let thirdStart = try XCTUnwrap(testStarts.map(\.offset).max())
        let firstEnd = try XCTUnwrap(testEnds.map(\.offset).min())
        XCTAssertGreaterThan(thirdStart, firstEnd)
    }

    func testWorkerReducesConcurrentDispatchWhenHostPressureIsConstrained() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .slowSuccess,
            extraEnv: [
                "XCSTEWARD_MAX_CONCURRENT_JOBS": "2",
                "XCSTEWARD_MEMORY_PRESSURE": "critical",
            ]
        )
        try createProfile(
            name: "demo-a",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-A"
            """
        )
        try createProfile(
            name: "demo-b",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-B"
            """
        )

        let first = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-a", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(first.status, 0, "stderr: \(first.stderr)")
        let firstJSON = try XCTUnwrap(parseJSON(first.stdout) as? [String: Any])
        let firstJobID = try XCTUnwrap(firstJSON["job_id"] as? String)

        let second = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-b", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(second.status, 0, "stderr: \(second.stderr)")
        let secondJSON = try XCTUnwrap(parseJSON(second.stdout) as? [String: Any])
        let secondJobID = try XCTUnwrap(secondJSON["job_id"] as? String)

        let firstBuildStarted = try waitUntil(timeout: 3) {
            guard FileManager.default.fileExists(atPath: fakeTools.log.path) else {
                return false
            }
            let toolLog = try String(contentsOf: fakeTools.log)
            return toolLog.components(separatedBy: "build-for-testing").count - 1 == 1
        }
        XCTAssertTrue(firstBuildStarted)
        Thread.sleep(forTimeInterval: 1)
        let toolLogWhileFirstIsActive = try String(contentsOf: fakeTools.log)
        XCTAssertEqual(toolLogWhileFirstIsActive.components(separatedBy: "build-for-testing").count - 1, 1)

        let health = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any])
        XCTAssertEqual(health["configured_max_jobs"] as? Int, 2)
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 1)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("memory_pressure=critical") == true)

        let bothFinished = try waitUntil(timeout: 20) {
            let firstStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, firstJobID, "--json"], environment: fakeTools.env)
            let secondStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, secondJobID, "--json"], environment: fakeTools.env)
            let firstStatusJSON = try XCTUnwrap(parseJSON(firstStatus.stdout) as? [String: Any])
            let secondStatusJSON = try XCTUnwrap(parseJSON(secondStatus.stdout) as? [String: Any])
            return (firstStatusJSON["state"] as? String) == "succeeded" &&
                (secondStatusJSON["state"] as? String) == "succeeded"
        }
        XCTAssertTrue(bothFinished)
    }

    func testWorkerRespectsActiveSimulatorLeaseBudget() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .slowSuccess,
            extraEnv: [
                "XCSTEWARD_MAX_CONCURRENT_JOBS": "2",
                "XCSTEWARD_MAX_ACTIVE_SIMULATOR_LEASES": "1",
            ]
        )
        try createProfile(
            name: "demo-a",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-A"
            """
        )
        try createProfile(
            name: "demo-b",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-B"
            """
        )

        let first = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-a", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(first.status, 0, "stderr: \(first.stderr)")
        let firstJSON = try XCTUnwrap(parseJSON(first.stdout) as? [String: Any])
        let firstJobID = try XCTUnwrap(firstJSON["job_id"] as? String)

        let second = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo-b", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(second.status, 0, "stderr: \(second.stderr)")
        let secondJSON = try XCTUnwrap(parseJSON(second.stdout) as? [String: Any])
        let secondJobID = try XCTUnwrap(secondJSON["job_id"] as? String)

        let firstBuildStarted = try waitUntil(timeout: 3) {
            guard FileManager.default.fileExists(atPath: fakeTools.log.path) else {
                return false
            }
            let toolLog = try String(contentsOf: fakeTools.log)
            return toolLog.components(separatedBy: "build-for-testing").count - 1 == 1
        }
        XCTAssertTrue(firstBuildStarted)
        Thread.sleep(forTimeInterval: 1)
        let toolLogWhileFirstIsActive = try String(contentsOf: fakeTools.log)
        XCTAssertEqual(toolLogWhileFirstIsActive.components(separatedBy: "build-for-testing").count - 1, 1)

        let health = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any])
        XCTAssertEqual(health["configured_max_jobs"] as? Int, 2)
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 1)
        XCTAssertEqual(health["max_active_simulator_leases"] as? Int, 1)
        XCTAssertTrue((health["reasons"] as? [String])?.contains { $0.hasPrefix("active_simulator_leases=") } == true)

        let bothFinished = try waitUntil(timeout: 20) {
            let firstStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, firstJobID, "--json"], environment: fakeTools.env)
            let secondStatus = try runCLI(arguments: ["status", "--state-root", stateRoot.path, secondJobID, "--json"], environment: fakeTools.env)
            let firstStatusJSON = try XCTUnwrap(parseJSON(firstStatus.stdout) as? [String: Any])
            let secondStatusJSON = try XCTUnwrap(parseJSON(secondStatus.stdout) as? [String: Any])
            return (firstStatusJSON["state"] as? String) == "succeeded" &&
                (secondStatusJSON["state"] as? String) == "succeeded"
        }
        XCTAssertTrue(bothFinished)
    }

    func testWorkerRunsQueuedJobsAfterInfrastructureDrainWindowClears() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: [
                "XCSTEWARD_MAX_CONCURRENT_JOBS": "2",
                "XCSTEWARD_INFRA_FAILURE_DRAIN_LIMIT": "1",
                "XCSTEWARD_RECENT_INFRA_FAILURE_WINDOW_SECONDS": "1",
            ]
        )
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        try store.recordInfrastructureEvent(
            jobID: "previous-job",
            simulatorID: "SIM-123",
            resultClass: .runnerBootstrapFailure,
            message: "previous infra failure"
        )
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

        let submit = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(submit.status, 0, "stderr: \(submit.stderr)")
        let submitJSON = try XCTUnwrap(parseJSON(submit.stdout) as? [String: Any])
        let jobID = try XCTUnwrap(submitJSON["job_id"] as? String)

        let healthWritten = try waitUntil(timeout: 3) {
            FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("host-health.json").path)
        }
        XCTAssertTrue(healthWritten)
        let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
        let statusJSON = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
        XCTAssertEqual(statusJSON["state"] as? String, "queued")

        let health = try XCTUnwrap(parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any])
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 0)
        XCTAssertEqual(health["draining"] as? Bool, true)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("drain_recent_infrastructure_failures=1") == true)

        if FileManager.default.fileExists(atPath: fakeTools.log.path) {
            let toolLog = try String(contentsOf: fakeTools.log)
            XCTAssertFalse(toolLog.contains("build-for-testing"))
        }

        let lease = try XCTUnwrap(try store.currentLease())
        XCTAssertTrue(isPIDAlive(lease.pid))

        let finishedAfterDrainClears = try waitUntil(timeout: 8) {
            let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
            let json = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
            return (json["state"] as? String) == "succeeded"
        }
        XCTAssertTrue(finishedAfterDrainClears)
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("build-for-testing"))
    }

    func testSerialWorkerWaitsForTemporaryInfrastructureDrainToClear() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: [
                "XCSTEWARD_INFRA_FAILURE_DRAIN_LIMIT": "1",
                "XCSTEWARD_RECENT_INFRA_FAILURE_WINDOW_SECONDS": "1",
            ]
        )
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        try store.recordInfrastructureEvent(
            jobID: "previous-job",
            simulatorID: "SIM-123",
            resultClass: .runnerBootstrapFailure,
            message: "previous infra failure"
        )
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

        let submit = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo", "--json"],
            environment: fakeTools.env
        )
        XCTAssertEqual(submit.status, 0, "stderr: \(submit.stderr)")
        let submitJSON = try XCTUnwrap(parseJSON(submit.stdout) as? [String: Any])
        let jobID = try XCTUnwrap(submitJSON["job_id"] as? String)

        let queuedDuringDrain = try waitUntil(timeout: 3) {
            let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
            let json = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
            return (json["state"] as? String) == "queued"
        }
        XCTAssertTrue(queuedDuringDrain)
        let lease = try XCTUnwrap(try store.currentLease())
        XCTAssertTrue(isPIDAlive(lease.pid))

        let finishedAfterDrainClears = try waitUntil(timeout: 8) {
            let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
            let json = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
            return (json["state"] as? String) == "succeeded"
        }
        XCTAssertTrue(finishedAfterDrainClears)
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("build-for-testing"))
    }

    func testRunningJobCancellationTerminatesActiveXcodebuildAndRecordsCanceledSummary() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .runningCancellation)
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

        let submit = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "demo",
                "--json",
            ],
            environment: fakeTools.env
        )
        XCTAssertEqual(submit.status, 0, "stderr: \(submit.stderr)")
        let submitJSON = try XCTUnwrap(parseJSON(submit.stdout) as? [String: Any])
        let jobID = try XCTUnwrap(submitJSON["job_id"] as? String)

        let buildStarted = try waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: fakeTools.root.appendingPathComponent("build-started").path)
        }
        XCTAssertTrue(buildStarted)

        let cancel = try runCLI(
            arguments: [
                "cancel",
                "--state-root", stateRoot.path,
                jobID,
                "--json",
            ],
            environment: fakeTools.env
        )
        XCTAssertEqual(cancel.status, 0, "stderr: \(cancel.stderr)")

        let canceled = try waitUntil(timeout: 5) {
            let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
            let statusJSON = try XCTUnwrap(parseJSON(status.stdout) as? [String: Any])
            return (statusJSON["state"] as? String) == "canceled"
        }
        XCTAssertTrue(canceled)
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcodebuild received SIGTERM"))
    }

    func testStatusLogsAndArtifactsCommandsExposeRecordedFiles() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
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

        let submit = try runCLI(
            arguments: ["submit", "--state-root", stateRoot.path, "--project", "demo", "--wait", "--json"],
            environment: fakeTools.env
        )
        let submitJSON = try XCTUnwrap(parseJSON(submit.stdout) as? [String: Any])
        let jobID = try XCTUnwrap(submitJSON["job_id"] as? String)

        let status = try runCLI(arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
        XCTAssertEqual(status.status, 0)

        let artifacts = try runCLI(arguments: ["artifacts", "--state-root", stateRoot.path, jobID, "--json"], environment: fakeTools.env)
        let artifactsJSON = try XCTUnwrap(parseJSON(artifacts.stdout) as? [String: Any])
        XCTAssertNotNil(artifactsJSON["xcresult"])

        let logs = try runCLI(arguments: ["logs", "--state-root", stateRoot.path, jobID], environment: fakeTools.env)
        XCTAssertTrue(logs.stdout.contains("Build succeeded"))
        XCTAssertTrue(logs.stdout.contains("Tests succeeded"))
    }
}

private func loadManualRunDiagnostics(from artifacts: [String: Any]) throws -> (summary: [String: Any], shards: [[String: Any]]) {
    let diagnosticsPath = try XCTUnwrap(artifacts["diagnostics"] as? String)
    let summary = try XCTUnwrap(parseJSON(String(contentsOfFile: diagnosticsPath)) as? [String: Any])
    let shards = try XCTUnwrap(summary["shards"] as? [[String: Any]])
    return (summary, shards)
}

private func logField(_ field: String, in line: Substring) -> String? {
    let prefix = "\(field)="
    return line.split(separator: " ")
        .first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count)) }
}

private func fakeToolEvents(at logURL: URL) throws -> [Substring] {
    guard FileManager.default.fileExists(atPath: logURL.path) else {
        return []
    }
    return try String(contentsOf: logURL)
        .split(separator: "\n")
        .filter { $0.hasPrefix("event ") }
}

private extension String {
    var isTerminalJobState: Bool {
        ["succeeded", "failed", "canceled", "interrupted"].contains(self)
    }
}
