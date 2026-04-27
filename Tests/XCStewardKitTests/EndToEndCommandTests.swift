import Foundation
import XCTest

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
        XCTAssertTrue(FileManager.default.fileExists(atPath: jobDir.appendingPathComponent("logs/combined.log").path))
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
        XCTAssertFalse(testLine.contains("-testPlan Stable"))
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
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl erase SIM-123"))
        XCTAssertFalse(toolLog.contains("shutdown all"))
        XCTAssertFalse(toolLog.contains("erase all"))
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

    func testExecutorFailsFastWhenCompetingSimulatorTestProcessIsActive() throws {
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

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertFalse(toolLog.contains("xcodebuild -project"))
    }

    func testSecondJobQueuesAndCanBeCanceledWhileFirstRuns() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .slowSuccess)
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
