import Foundation
import XCTest

final class CheckedSwiftTestFilterScriptTests: XCTestCase {
    func testCheckedSwiftTestFilterRequiresAFilterBeforeInvokingSwift() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        let swiftLog = temp.appendingPathComponent("swift.log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(swiftLog.path)"
            exit 0
            """,
            to: bin.appendingPathComponent("swift")
        )

        let result = try runRepoScript(
            "scripts/run-swift-test-filter.sh",
            arguments: [],
            environment: ["PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"]
        )

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("require at least one --filter"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: swiftLog.path))
    }

    func testCheckedSwiftTestFilterPassesThroughSuccessfulFilteredRuns() throws {
        let fixture = try makeFakeSwiftFixture(mode: "success")
        let result = try runRepoScript(
            "scripts/run-swift-test-filter.sh",
            arguments: ["--filter", "SomeTests/testPasses"],
            environment: fixture.environment
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Executed 1 test"))
        let swiftLog = try String(contentsOf: fixture.log)
        XCTAssertTrue(swiftLog.contains("test --filter SomeTests/testPasses"))
    }

    func testCheckedSwiftTestFilterFailsWhenSwiftPMReportsZeroMatchingTests() throws {
        let fixture = try makeFakeSwiftFixture(mode: "zero-match")
        let result = try runRepoScript(
            "scripts/run-swift-test-filter.sh",
            arguments: ["test", "--filter", "MissingTests/testMissing"],
            environment: fixture.environment
        )

        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.stderr.contains("No matching test cases were run"))
        XCTAssertTrue(result.stderr.contains("filter matched zero test cases"))
        let swiftLog = try String(contentsOf: fixture.log)
        XCTAssertTrue(swiftLog.contains("test --filter MissingTests/testMissing"))
    }

    func testHardeningMatrixRunnerFailsWhenASelectedRowMatchesZeroTests() throws {
        let temp = try makeTempDirectory()
        let matrix = temp.appendingPathComponent("matrix.md")
        let report = temp.appendingPathComponent("report.json")
        let fixture = try makeFakeSwiftFixture(mode: "zero-match", under: temp)
        try writeText(
            """
            | Row ID | Command | Expected Result |
            | --- | --- | --- |
            | `stale-filter` | `swift test --filter MissingTests/testMissing` | Stale filters must fail the release gate. |
            """,
            to: matrix
        )

        var environment = fixture.environment
        environment["XCSTEWARD_HARDENING_MATRIX_FILE"] = matrix.path
        let result = try runRepoScript(
            "scripts/run-hardening-matrix.sh",
            arguments: ["--report", report.path],
            environment: environment
        )

        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.stdout.contains("[1/1] stale-filter"))
        XCTAssertTrue(result.stderr.contains("filter matched zero test cases"))

        let reportJSON = try XCTUnwrap(parseJSON(try String(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportJSON["status"] as? String, "failed")
        XCTAssertEqual(reportJSON["failed_count"] as? Int, 1)
        let rows = try XCTUnwrap(reportJSON["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"] as? String, "stale-filter")
        XCTAssertEqual(rows[0]["status"] as? String, "failed")
        XCTAssertEqual(rows[0]["exit_code"] as? Int, 64)
    }
}

final class FakeToolScriptSelfTests: XCTestCase {
    func testGeneratedFakeToolScriptsPassBashSyntaxCheck() throws {
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        for toolName in baselineFakeToolNames {
            let script = fakeTools.bin.appendingPathComponent(toolName)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path), "\(toolName) should be executable")
            let result = try runProcess(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-n", script.path],
                environment: fakeTools.env
            )
            XCTAssertEqual(result.status, 0, "\(toolName) syntax failed: \(result.stderr)")
        }
    }

    func testGeneratedFakeToolsSupportBaselineCommands() throws {
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)

        try assertFakeTool(fakeTools, "xcodebuild", ["-version"], stdoutContains: "Xcode 16.4")
        try assertFakeTool(fakeTools, "xcodebuild", ["-showdestinations"], stdoutContains: "SIM-123")
        try assertFakeTool(fakeTools, "xcrun", ["--find", "xcodebuild"], stdoutContains: "FakeXcode.app/Contents/Developer/usr/bin/xcodebuild")
        try assertFakeTool(fakeTools, "xcrun", ["simctl", "list", "runtimes", "--json"], stdoutContains: "com.apple.CoreSimulator.SimRuntime.iOS-18-0")
        try assertFakeTool(fakeTools, "ps", ["-axo", "pid=,command="], stdoutContains: "PID COMMAND")
        try assertFakeTool(fakeTools, "memory_pressure", [], stdoutContains: "Memory pressure: Normal")
        try assertFakeTool(fakeTools, "pmset", ["-g", "therm"], stdoutContains: "CPU_Scheduler_Limit = 100")
        try assertFakeTool(fakeTools, "xcode-select", ["-p"], stdoutContains: "FakeXcode.app/Contents/Developer")
    }

    private var baselineFakeToolNames: [String] {
        ["xcodebuild", "xcrun", "ps", "memory_pressure", "pmset", "xcode-select"]
    }

    private func assertFakeTool(
        _ fakeTools: FakeToolEnvironment,
        _ toolName: String,
        _ arguments: [String],
        stdoutContains expectedOutput: String
    ) throws {
        let result = try runProcess(
            executable: fakeTools.bin.appendingPathComponent(toolName),
            arguments: arguments,
            environment: fakeTools.env
        )
        XCTAssertEqual(result.status, 0, "\(toolName) failed: \(result.stderr)")
        XCTAssertTrue(
            result.stdout.contains(expectedOutput),
            "\(toolName) stdout did not contain \(expectedOutput). stdout: \(result.stdout)"
        )
    }
}

final class TestSuiteTierScriptTests: XCTestCase {
    func testTestSuiteScriptListsFastAndReleaseGroups() throws {
        let fast = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--tier", "fast", "--list"]
        )
        XCTAssertEqual(fast.status, 0, "stderr: \(fast.stderr)")
        XCTAssertTrue(fast.stdout.contains("unit-core\tfast"))
        XCTAssertTrue(fast.stdout.contains("script-hardening\tfast"))
        XCTAssertFalse(fast.stdout.contains("doctor-preflight\trelease"))

        let release = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--tier", "release", "--list"]
        )
        XCTAssertEqual(release.status, 0, "stderr: \(release.stderr)")
        XCTAssertTrue(release.stdout.contains("unit-core\tfast"))
        XCTAssertTrue(release.stdout.contains("doctor-preflight\trelease"))
        XCTAssertTrue(release.stdout.contains("e2e-command-surface\trelease"))
        XCTAssertFalse(release.stdout.contains("live-xcode-managed-smoke\tlive"))
        XCTAssertTrue(release.stderr.contains("live-xcode-managed-smoke skipped"))

        let live = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--tier", "live", "--list"]
        )
        XCTAssertEqual(live.status, 0, "stderr: \(live.stderr)")
        XCTAssertTrue(live.stdout.contains("live-xcode-managed-smoke\tlive"))
    }

    func testTestSuiteScriptValidatesReleaseCoverage() throws {
        let result = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--tier", "release", "--check-coverage"]
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("covers all non-live XCTestCase classes exactly once"))
    }

    func testTestSuiteScriptFailsBeforeRunningWhenAGroupReferencesAStaleFilterClass() throws {
        let temp = try makeTempDirectory()
        let groups = temp.appendingPathComponent("groups.txt")
        let fixture = try makeFakeSwiftFixture(mode: "success", under: temp)
        try writeText(
            """
            stale-filter|fast|MissingSuiteTests TestSuiteTierScriptTests|A stale class mixed with a valid class must fail before SwiftPM runs.
            """,
            to: groups
        )

        var environment = fixture.environment
        environment["XCSTEWARD_TEST_SUITE_GROUPS_FILE"] = groups.path
        let result = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--group", "stale-filter"],
            environment: environment
        )

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("selected test-suite filters do not match XCTestCase classes"))
        XCTAssertTrue(result.stderr.contains("MissingSuiteTests"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
    }

    func testTestSuiteScriptFailsBeforeRunningForMalformedGroupRows() throws {
        let temp = try makeTempDirectory()
        let groups = temp.appendingPathComponent("groups.txt")
        let fixture = try makeFakeSwiftFixture(mode: "success", under: temp)
        try writeText(
            """
            malformed|fast|TestSuiteTierScriptTests
            """,
            to: groups
        )

        var environment = fixture.environment
        environment["XCSTEWARD_TEST_SUITE_GROUPS_FILE"] = groups.path
        let result = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--tier", "fast"],
            environment: environment
        )

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("malformed test-suite group row"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
    }

    func testTestSuiteScriptFailsBeforeRunningForDuplicateGroupIDs() throws {
        let temp = try makeTempDirectory()
        let groups = temp.appendingPathComponent("groups.txt")
        let fixture = try makeFakeSwiftFixture(mode: "success", under: temp)
        try writeText(
            """
            duplicate|fast|TestSuiteTierScriptTests|First owner.
            duplicate|fast|CheckedSwiftTestFilterScriptTests|Second owner.
            """,
            to: groups
        )

        var environment = fixture.environment
        environment["XCSTEWARD_TEST_SUITE_GROUPS_FILE"] = groups.path
        let result = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--tier", "fast"],
            environment: environment
        )

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("duplicate test-suite group IDs"))
        XCTAssertTrue(result.stderr.contains("duplicate"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
    }

    func testTestSuiteScriptFailsBeforeRunningWhenASelectionDuplicatesAFilterClass() throws {
        let temp = try makeTempDirectory()
        let groups = temp.appendingPathComponent("groups.txt")
        let fixture = try makeFakeSwiftFixture(mode: "success", under: temp)
        try writeText(
            """
            duplicate-filter|fast|TestSuiteTierScriptTests TestSuiteTierScriptTests|A duplicate class owner must fail before SwiftPM runs.
            """,
            to: groups
        )

        var environment = fixture.environment
        environment["XCSTEWARD_TEST_SUITE_GROUPS_FILE"] = groups.path
        let result = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--group", "duplicate-filter"],
            environment: environment
        )

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("duplicate XCTestCase classes"))
        XCTAssertTrue(result.stderr.contains("TestSuiteTierScriptTests"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
    }

    func testTestSuiteScriptWritesSuiteHealthReportForGroup() throws {
        let temp = try makeTempDirectory()
        let report = temp.appendingPathComponent("suite-report.json")
        let fixture = try makeFakeSwiftFixture(mode: "success", under: temp)

        let result = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--group", "script-hardening", "--report", report.path],
            environment: fixture.environment
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("[1/1] script-hardening"))
        XCTAssertTrue(result.stdout.contains("Test suite report: \(report.path)"))

        let reportJSON = try XCTUnwrap(parseJSON(try String(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportJSON["status"] as? String, "passed")
        XCTAssertEqual(reportJSON["tier"] as? String, "fast")
        XCTAssertEqual(reportJSON["selected_group_count"] as? Int, 1)
        XCTAssertEqual(reportJSON["group_count"] as? Int, 1)
        XCTAssertEqual(reportJSON["failed_count"] as? Int, 0)
        XCTAssertEqual(reportJSON["test_count"] as? Int, 1)
        XCTAssertEqual(reportJSON["failure_count"] as? Int, 0)
        XCTAssertEqual(reportJSON["continue_on_failure"] as? Bool, false)
        XCTAssertEqual(reportJSON["live_included"] as? Bool, false)
        XCTAssertEqual(reportJSON["live_skipped"] as? Bool, false)
        XCTAssertEqual(reportJSON["live_smoke_status"] as? String, "not_requested")
        let slowest = try XCTUnwrap(reportJSON["slowest_groups"] as? [[String: Any]])
        XCTAssertEqual(slowest.first?["id"] as? String, "script-hardening")
        let groups = try XCTUnwrap(reportJSON["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["id"] as? String, "script-hardening")
        XCTAssertEqual(groups[0]["status"] as? String, "passed")
        XCTAssertTrue((groups[0]["filters"] as? String)?.contains("HardeningMatrixTests") == true)
        let logsDir = try XCTUnwrap(reportJSON["logs_dir"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logsDir))
    }

    func testTestSuiteScriptLabelsReleaseTierGroupsInReports() throws {
        let temp = try makeTempDirectory()
        let report = temp.appendingPathComponent("doctor-group-report.json")
        let fixture = try makeFakeSwiftFixture(mode: "success", under: temp)

        let result = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--group", "doctor-preflight", "--report", report.path],
            environment: fixture.environment
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let reportJSON = try XCTUnwrap(parseJSON(try String(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportJSON["tier"] as? String, "release")
        let groups = try XCTUnwrap(reportJSON["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.first?["tier"] as? String, "release")
        XCTAssertTrue((groups.first?["filters"] as? String)?.contains("DoctorXcodeEnvironmentCommandTests") == true)
    }

    func testTestSuiteScriptRecordsFailingGroupInReport() throws {
        let temp = try makeTempDirectory()
        let report = temp.appendingPathComponent("suite-failure.json")
        let fixture = try makeFakeSwiftFixture(mode: "failure", under: temp)

        let result = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--group", "script-hardening", "--report", report.path],
            environment: fixture.environment
        )

        XCTAssertEqual(result.status, 9)
        XCTAssertTrue(result.stdout.contains("Test suite report: \(report.path)"))

        let reportJSON = try XCTUnwrap(parseJSON(try String(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportJSON["status"] as? String, "failed")
        XCTAssertEqual(reportJSON["failed_count"] as? Int, 1)
        let groups = try XCTUnwrap(reportJSON["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["id"] as? String, "script-hardening")
        XCTAssertEqual(groups[0]["status"] as? String, "failed")
        XCTAssertEqual(groups[0]["exit_code"] as? Int, 9)
    }

    func testTestSuiteScriptFailsWhenAGroupReportsZeroExecutedTests() throws {
        let temp = try makeTempDirectory()
        let report = temp.appendingPathComponent("zero-tests.json")
        let fixture = try makeFakeSwiftFixture(mode: "zero-executed", under: temp)

        let result = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--group", "script-hardening", "--report", report.path],
            environment: fixture.environment
        )

        XCTAssertEqual(result.status, 65)
        XCTAssertTrue(result.stderr.contains("test-suite group executed zero tests"))
        XCTAssertTrue(result.stdout.contains("Test suite report: \(report.path)"))

        let reportJSON = try XCTUnwrap(parseJSON(try String(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportJSON["status"] as? String, "failed")
        XCTAssertEqual(reportJSON["failed_count"] as? Int, 1)
        XCTAssertEqual(reportJSON["test_count"] as? Int, 0)
        let groups = try XCTUnwrap(reportJSON["groups"] as? [[String: Any]])
        XCTAssertEqual(groups[0]["status"] as? String, "failed")
        XCTAssertEqual(groups[0]["exit_code"] as? Int, 65)
        XCTAssertEqual(groups[0]["test_count"] as? Int, 0)
    }

    func testTestSuiteScriptContinueOnFailureRunsRemainingGroupsAndReportsSelection() throws {
        let temp = try makeTempDirectory()
        let report = temp.appendingPathComponent("continue-report.json")
        let groupsFile = temp.appendingPathComponent("groups.txt")
        let fixture = try makeFakeSwiftFixture(mode: "fail-first-filter", under: temp)
        try writeText(
            """
            first|fast|TestSuiteTierScriptTests|First group fails.
            second|fast|CheckedSwiftTestFilterScriptTests|Second group still runs.
            """,
            to: groupsFile
        )

        var environment = fixture.environment
        environment["XCSTEWARD_TEST_SUITE_GROUPS_FILE"] = groupsFile.path
        let result = try runRepoScript(
            "scripts/run-test-suite.sh",
            arguments: ["--tier", "fast", "--continue-on-failure", "--report", report.path],
            environment: environment
        )

        XCTAssertEqual(result.status, 9)
        XCTAssertTrue(result.stdout.contains("[1/2] first"))
        XCTAssertTrue(result.stdout.contains("[2/2] second"))

        let reportJSON = try XCTUnwrap(parseJSON(try String(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportJSON["status"] as? String, "failed")
        XCTAssertEqual(reportJSON["selected_group_count"] as? Int, 2)
        XCTAssertEqual(reportJSON["group_count"] as? Int, 2)
        XCTAssertEqual(reportJSON["failed_count"] as? Int, 1)
        XCTAssertEqual(reportJSON["continue_on_failure"] as? Bool, true)
        let groups = try XCTUnwrap(reportJSON["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.map { $0["id"] as? String }, ["first", "second"])
        XCTAssertEqual(groups.map { $0["status"] as? String }, ["failed", "passed"])
    }
}

private struct FakeSwiftFixture {
    let log: URL
    let environment: [String: String]
}

private func makeFakeSwiftFixture(mode: String, under existingRoot: URL? = nil) throws -> FakeSwiftFixture {
    let root: URL
    if let existingRoot {
        root = existingRoot
    } else {
        root = try makeTempDirectory()
    }
    let bin = root.appendingPathComponent("bin")
    let log = root.appendingPathComponent("swift.log")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try writeExecutable(
        """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(log.path)"
        case "${FAKE_SWIFT_MODE:-success}" in
          zero-match)
            echo 'warning: No matching test cases were run' >&2
            exit 0
            ;;
          fail-first-filter)
            case "$*" in
              *TestSuiteTierScriptTests*)
                echo 'compile failed' >&2
                exit 9
                ;;
              *)
                echo 'Test Suite passed'
                echo 'Executed 1 test, with 0 failures'
                exit 0
                ;;
            esac
            ;;
          failure)
            echo 'compile failed' >&2
            exit 9
            ;;
          zero-executed)
            echo 'Test Suite passed'
            echo 'Executed 0 tests, with 0 failures'
            exit 0
            ;;
          *)
            echo 'Test Suite passed'
            echo 'Executed 1 test, with 0 failures'
            exit 0
            ;;
        esac
        """,
        to: bin.appendingPathComponent("swift")
    )
    return FakeSwiftFixture(
        log: log,
        environment: [
            "PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
            "SWIFT_EXECUTABLE": bin.appendingPathComponent("swift").path,
            "FAKE_SWIFT_MODE": mode,
        ]
    )
}

private func runRepoScript(
    _ script: String,
    arguments: [String],
    environment: [String: String] = [:]
) throws -> CLIResult {
    try runProcess(
        executable: URL(fileURLWithPath: "/bin/bash"),
        arguments: [script] + arguments,
        environment: environment,
        currentDirectoryURL: repoRootURLForTestSuiteHardening()
    )
}

private func runProcess(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL? = nil
) throws -> CLIResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    var mergedEnvironment = ProcessInfo.processInfo.environment
    for (key, value) in environment {
        mergedEnvironment[key] = value
    }
    process.environment = mergedEnvironment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    return CLIResult(
        status: process.terminationStatus,
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private func repoRootURLForTestSuiteHardening() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
