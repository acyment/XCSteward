import Foundation
import XCTest

final class XcodeManagedConfigurationE2ETests: XCTestCase {
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
}
