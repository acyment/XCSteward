import Foundation
import XCTest
@testable import XCStewardKit

final class ResultReporterTests: XCTestCase {
    func testParsesModernSummaryAndTimingSamples() throws {
        let temp = try makeTempDirectory()
        let resultBundle = temp.appendingPathComponent("result.xcresult")
        try FileManager.default.createDirectory(at: resultBundle, withIntermediateDirectories: true)
        let runner = StubToolRunner { _, arguments in
            if arguments.contains("summary") {
                return ToolResult(
                    exitCode: 0,
                    output: #"{"totalTestCount":3,"failedTests":1,"skippedTests":1}"#,
                    timedOut: false
                )
            }
            if arguments.contains("tests") {
                return ToolResult(
                    exitCode: 0,
                    output: #"{"tests":[{"identifier":"DemoTests/FooTests/testA","duration":1.25},{"name":"DemoTests/BarTests/testB","time_seconds":"2.5"}]}"#,
                    timedOut: false
                )
            }
            return ToolResult(exitCode: 1, output: "", timedOut: false)
        }
        let reporter = ResultReporter(environment: AppEnvironment(
            paths: AppPaths(stateRoot: temp.appendingPathComponent("state")),
            toolRunner: runner
        ))

        let summary = try XCTUnwrap(reporter.parseXCResultSummary(at: resultBundle))
        let counts = try XCTUnwrap(reporter.counts(from: summary))
        let timings = reporter.parseXCResultTestTimings(at: resultBundle)

        XCTAssertEqual(counts.testsRun, 3)
        XCTAssertEqual(counts.testsFailed, 1)
        XCTAssertEqual(counts.testsSkipped, 1)
        XCTAssertEqual(timings.map(\.identifier), ["DemoTests/BarTests/testB", "DemoTests/FooTests/testA"])
        XCTAssertEqual(timings.map(\.durationSeconds), [2.5, 1.25])
    }

    func testParsesOneSecondTimingSamplesWithoutTreatingThemAsBooleans() throws {
        let samples = try XCResultParser().testTimingSamples(
            from: Data(#"{"tests":[{"identifier":"DemoTests/FooTests/testA","duration":1.0},{"identifier":"DemoTests/FooTests/testB","duration":true}]}"#.utf8)
        )

        XCTAssertEqual(samples.map(\.identifier), ["DemoTests/FooTests/testA"])
        XCTAssertEqual(samples.map(\.durationSeconds), [1.0])
    }

    func testWritesJUnitReport() throws {
        let temp = try makeTempDirectory()
        let output = temp.appendingPathComponent("junit.xml")
        let reporter = ResultReporter(environment: AppEnvironment(paths: AppPaths(stateRoot: temp.appendingPathComponent("state"))))

        try reporter.writeJUnitReport(
            project: "Demo & App",
            resultClass: .testFailure,
            counts: JobCounts(testsRun: 2, testsFailed: 1, testsSkipped: 0),
            durationSeconds: 1.23456,
            cases: [
                JUnitTestCase(
                    className: "DemoTests.FooTests",
                    name: "testEscapes<&>",
                    timeSeconds: 0.5,
                    failureMessage: "failed <because>",
                    errorMessage: nil,
                    skipped: false
                ),
            ],
            outputURL: output
        )

        let xml = try String(contentsOf: output)
        XCTAssertTrue(xml.contains("name=\"Demo &amp; App\""))
        XCTAssertTrue(xml.contains("tests=\"2\""))
        XCTAssertTrue(xml.contains("failures=\"1\""))
        XCTAssertTrue(xml.contains("time=\"1.235\""))
        XCTAssertTrue(xml.contains("testEscapes&lt;&amp;&gt;"))
        XCTAssertTrue(xml.contains("failed &lt;because&gt;"))
    }

    func testWritesRunMetadataWithXcodeProbeArtifacts() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let request = reporterRequest(testPlan: "Smoke", onlyTesting: ["DemoTests/FooTests/testA"])
        let job = reporterJob(request: request, directory: temp.appendingPathComponent("job"))
        let paths = ExecutionPaths(job: job)
        try paths.createDirectories(using: LocalFileSystem())
        let profile = reporterProfile(repoRoot: temp.appendingPathComponent("repo").path)
        let summary = JobSummary(
            jobID: job.id,
            project: job.project,
            state: .succeeded,
            resultClass: .success,
            exitCode: 0,
            submittedAt: 1,
            startedAt: 2,
            finishedAt: 5,
            durationSeconds: 3,
            testPlan: "Smoke",
            onlyTesting: request.onlyTesting,
            simulatorID: "SIM-123",
            counts: JobCounts(testsRun: 1, testsFailed: 0, testsSkipped: 0),
            artifacts: paths.artifacts(fileSystem: LocalFileSystem()),
            summaryLine: "Tests succeeded",
            metadata: ["source": "test"]
        )
        let runner = StubToolRunner { tool, arguments in
            if tool == "xcrun", arguments == ["--find", "xcodebuild"] {
                return ToolResult(exitCode: 0, output: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild\n", timedOut: false)
            }
            if arguments == ["-help"] {
                return ToolResult(exitCode: 0, output: "xcodebuild help text", timedOut: false)
            }
            if arguments == ["-version"] {
                return ToolResult(exitCode: 0, output: "Xcode 16.4\nBuild version 16F6\n", timedOut: false)
            }
            return ToolResult(exitCode: 1, output: "", timedOut: false)
        }
        let reporter = ResultReporter(environment: AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            toolRunner: runner
        ))

        try reporter.writeRunMetadata(summary: summary, profile: profile, request: request, paths: paths)

        let metadata = try XCTUnwrap(parseJSON(String(contentsOf: paths.runMetadata)) as? [String: Any])
        XCTAssertEqual(metadata["job_id"] as? String, "job-123")
        XCTAssertEqual(metadata["simulator_id"] as? String, "SIM-123")
        XCTAssertEqual((metadata["exit_code"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(metadata["timed_out"] as? Bool, false)
        XCTAssertEqual(metadata["canceled"] as? Bool, false)
        XCTAssertTrue((metadata["xcode_version"] as? String)?.contains("Xcode 16.4") == true)
        XCTAssertEqual(metadata["xcodebuild_path"] as? String, "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild")
        XCTAssertEqual(metadata["derived_data_path"] as? String, paths.derivedData.path)
        XCTAssertEqual(metadata["summary_path"] as? String, paths.summary.path)
        let helpPath = try XCTUnwrap(metadata["xcodebuild_help_path"] as? String)
        XCTAssertEqual(try String(contentsOfFile: helpPath), "xcodebuild help text")
        let requestMetadata = try XCTUnwrap(metadata["request"] as? [String: Any])
        XCTAssertEqual(requestMetadata["test_plan"] as? String, "Smoke")
    }

    func testWritesRunMetadataWithProbeWarnings() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let request = reporterRequest()
        let job = reporterJob(request: request, directory: temp.appendingPathComponent("job"))
        let paths = ExecutionPaths(job: job)
        try paths.createDirectories(using: LocalFileSystem())
        let resultBundle = paths.resultBundle
        try FileManager.default.createDirectory(at: resultBundle, withIntermediateDirectories: true)
        let profile = reporterProfile(repoRoot: temp.appendingPathComponent("repo").path)
        let summary = JobSummary(
            jobID: job.id,
            project: job.project,
            state: .failed,
            resultClass: .artifactFailure,
            exitCode: 65,
            submittedAt: 1,
            startedAt: 2,
            finishedAt: 5,
            durationSeconds: 3,
            testPlan: nil,
            onlyTesting: [],
            simulatorID: "SIM-123",
            counts: nil,
            artifacts: paths.artifacts(fileSystem: LocalFileSystem()),
            summaryLine: "Artifacts missing",
            metadata: [:]
        )
        var healthyXcodeProbes = false
        let runner = StubToolRunner { tool, arguments in
            if tool == "xcrun", arguments == ["--find", "xcodebuild"] {
                if healthyXcodeProbes {
                    return ToolResult(exitCode: 0, output: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild\n", timedOut: false)
                }
                return ToolResult(exitCode: 72, output: "xcodebuild not found", timedOut: false)
            }
            if arguments.contains("summary") {
                return ToolResult(exitCode: 0, output: "not json", timedOut: false)
            }
            if arguments.contains("tests") {
                return ToolResult(exitCode: 9, output: "test timing probe failed", timedOut: false)
            }
            if arguments == ["-help"] {
                if healthyXcodeProbes {
                    return ToolResult(exitCode: 0, output: "xcodebuild help text", timedOut: false)
                }
                return ToolResult(exitCode: 72, output: "help unavailable", timedOut: false)
            }
            if arguments == ["-version"] {
                if healthyXcodeProbes {
                    return ToolResult(exitCode: 0, output: "Xcode 16.4\nBuild version 16F6\n", timedOut: false)
                }
                return ToolResult(exitCode: 0, output: "not xcode", timedOut: false)
            }
            return ToolResult(exitCode: 1, output: "", timedOut: false)
        }
        let reporter = ResultReporter(environment: AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            toolRunner: runner
        ))

        XCTAssertNil(reporter.parseXCResultSummary(at: resultBundle))
        XCTAssertTrue(reporter.parseXCResultTestTimings(at: resultBundle).isEmpty)
        try reporter.writeRunMetadata(summary: summary, profile: profile, request: request, paths: paths)

        let metadata = try XCTUnwrap(parseJSON(String(contentsOf: paths.runMetadata)) as? [String: Any])
        let warnings = try XCTUnwrap(metadata["probe_warnings"] as? [[String: Any]])
        XCTAssertEqual(Set(warnings.compactMap { $0["source"] as? String }), [
            "xcresulttool.summary",
            "xcresulttool.tests",
            "xcodebuild.help",
            "xcodebuild.path",
            "xcodebuild.version",
        ])
        let helpWarning = try XCTUnwrap(warnings.first { ($0["source"] as? String) == "xcodebuild.help" })
        XCTAssertEqual((helpWarning["exit_code"] as? NSNumber)?.intValue, 72)
        XCTAssertEqual(helpWarning["output_excerpt"] as? String, "help unavailable")
        let summaryWarning = try XCTUnwrap(warnings.first { ($0["source"] as? String) == "xcresulttool.summary" })
        XCTAssertTrue((summaryWarning["message"] as? String)?.contains("unparseable") == true)

        healthyXcodeProbes = true
        let secondJob = reporterJob(request: request, directory: temp.appendingPathComponent("job-2"))
        let secondPaths = ExecutionPaths(job: secondJob)
        try secondPaths.createDirectories(using: LocalFileSystem())
        var secondSummary = summary
        secondSummary.jobID = secondJob.id
        secondSummary.artifacts = secondPaths.artifacts(fileSystem: LocalFileSystem())

        try reporter.writeRunMetadata(summary: secondSummary, profile: profile, request: request, paths: secondPaths)

        let secondMetadata = try XCTUnwrap(parseJSON(String(contentsOf: secondPaths.runMetadata)) as? [String: Any])
        XCTAssertEqual((secondMetadata["probe_warnings"] as? [[String: Any]])?.count, 0)
    }

    func testRetriesTimedOutXcodebuildHelpProbeBeforeRecordingWarning() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let request = reporterRequest()
        let job = reporterJob(request: request, directory: temp.appendingPathComponent("job"))
        let paths = ExecutionPaths(job: job)
        try paths.createDirectories(using: LocalFileSystem())
        let profile = reporterProfile(repoRoot: temp.appendingPathComponent("repo").path)
        let summary = JobSummary(
            jobID: job.id,
            project: job.project,
            state: .succeeded,
            resultClass: .success,
            exitCode: 0,
            submittedAt: 1,
            startedAt: 2,
            finishedAt: 5,
            durationSeconds: 3,
            testPlan: nil,
            onlyTesting: [],
            simulatorID: "SIM-123",
            counts: JobCounts(testsRun: 1, testsFailed: 0, testsSkipped: 0),
            artifacts: paths.artifacts(fileSystem: LocalFileSystem()),
            summaryLine: "Tests succeeded",
            metadata: [:]
        )
        var helpProbeTimeouts: [TimeInterval?] = []
        let runner = StubToolRunner { tool, arguments, timeout in
            if tool == "xcrun", arguments == ["--find", "xcodebuild"] {
                return ToolResult(exitCode: 0, output: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild\n", timedOut: false)
            }
            if arguments == ["-help"] {
                helpProbeTimeouts.append(timeout)
                if helpProbeTimeouts.count == 1 {
                    return ToolResult(exitCode: 143, output: "", timedOut: true)
                }
                return ToolResult(exitCode: 0, output: "retried help text", timedOut: false)
            }
            if arguments == ["-version"] {
                return ToolResult(exitCode: 0, output: "Xcode 16.4\nBuild version 16F6\n", timedOut: false)
            }
            return ToolResult(exitCode: 1, output: "", timedOut: false)
        }
        let reporter = ResultReporter(environment: AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            toolRunner: runner
        ))

        try reporter.writeRunMetadata(summary: summary, profile: profile, request: request, paths: paths)

        let metadata = try XCTUnwrap(parseJSON(String(contentsOf: paths.runMetadata)) as? [String: Any])
        XCTAssertEqual(helpProbeTimeouts, [5, 30])
        let helpPath = try XCTUnwrap(metadata["xcodebuild_help_path"] as? String)
        XCTAssertEqual(try String(contentsOfFile: helpPath), "retried help text")
        XCTAssertEqual((metadata["probe_warnings"] as? [[String: Any]])?.count, 0)
    }

    func testWritesManualShardDiagnostics() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let environment = AppEnvironment(paths: AppPaths(stateRoot: stateRoot))
        let store = try StateStore(environment: environment)
        let request = reporterRequest()
        let job = reporterJob(request: request, directory: temp.appendingPathComponent("job"))
        let paths = ExecutionPaths(job: job)
        try paths.createDirectories(using: LocalFileSystem())
        let context = ToolExecutionContext(
            profile: reporterProfile(repoRoot: temp.appendingPathComponent("repo").path),
            jobID: job.id,
            store: store
        )
        let reporter = ResultReporter(environment: environment)

        try reporter.writeManualRunDiagnostics(
            resultClass: .runnerBootstrapFailure,
            counts: nil,
            reports: [
                ShardReport(
                    shardID: "shard-000",
                    simulatorID: "SIM-1",
                    onlyTesting: ["DemoTests/FooTests/testA"],
                    resultBundle: "/tmp/shard-000.xcresult",
                    resultStream: nil,
                    log: "/tmp/shard-000.log",
                    resultClass: .runnerBootstrapFailure,
                    exitCode: 65,
                    counts: nil,
                    attempts: 2,
                    retryReason: "runner_bootstrap_failure",
                    simulatorDiagnostics: ["/tmp/diagnose.log"]
                ),
            ],
            paths: paths,
            context: context
        )

        let json = try XCTUnwrap(parseJSON(String(contentsOf: paths.combinedSummary)) as? [String: Any])
        XCTAssertEqual(json["job_id"] as? String, "job-123")
        XCTAssertEqual(json["shard_count"] as? Int, 1)
        XCTAssertEqual(json["retry_count"] as? Int, 1)
        XCTAssertEqual(json["failed_shard_count"] as? Int, 1)
        XCTAssertEqual(json["simulator_diagnostics"] as? [String], ["/tmp/diagnose.log"])
    }
}

private final class StubToolRunner: ToolRunning {
    private let handler: (String, [String], TimeInterval?) -> ToolResult

    init(handler: @escaping (String, [String]) -> ToolResult) {
        self.handler = { tool, arguments, _ in
            handler(tool, arguments)
        }
    }

    init(handler: @escaping (String, [String], TimeInterval?) -> ToolResult) {
        self.handler = handler
    }

    func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)?
    ) throws -> ToolResult {
        handler(tool, arguments, timeout)
    }
}

private func reporterProfile(repoRoot: String) -> ProjectProfile {
    ProjectProfile(
        name: "demo",
        repoRoot: repoRoot,
        projectPath: "App.xcodeproj",
        workspacePath: nil,
        scheme: "Demo",
        defaultSimulatorID: "SIM-123",
        managedSimulator: nil,
        defaultTestPlan: nil,
        allowedSimulatorIDs: [],
        env: [:],
        timeouts: Timeouts(),
        resetPolicy: nil,
        parallel: ParallelSettings(),
        ports: nil,
        xctestTimeouts: XCTestTimeoutSettings(),
        xctestRetries: XCTestRetrySettings(),
        xctestDiagnostics: XCTestDiagnosticSettings(),
        destination: XcodeDestinationSettings(),
        coverage: CodeCoverageSettings(),
        resultStream: ResultStreamSettings(),
        resultBundle: ResultBundleSettings(),
        testProducts: TestProductsSettings(),
        privacy: SimulatorPrivacySettings()
    )
}

private func reporterRequest(
    testPlan: String? = nil,
    onlyTesting: [String] = []
) -> JobRequest {
    JobRequest(
        project: "demo",
        testPlan: testPlan,
        onlyTesting: onlyTesting,
        simulatorID: nil,
        metadata: [:],
        wait: false
    )
}

private func reporterJob(request: JobRequest, directory: URL) -> JobRecord {
    JobRecord(
        id: "job-123",
        project: "demo",
        state: .queued,
        resultClass: nil,
        request: request,
        summary: nil,
        jobDirectory: directory.path,
        createdAt: 1,
        startedAt: nil,
        finishedAt: nil,
        processID: nil,
        simulatorID: nil,
        cancelRequested: false
    )
}
