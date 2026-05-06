import Foundation
import XCTest
@testable import XCStewardKit

final class ManualShardRunnerServiceBoundaryTests: XCTestCase {
    func testRunnerUsesRuntimeProtocolInsteadOfConcreteExecutor() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            clock: StickyManualShardClock(start: 100, later: 105),
            toolRunner: ManualShardXCResultToolRunner()
        )
        let store = try StateStore(environment: environment)
        let request = JobRequest(
            project: "demo",
            testPlan: nil,
            onlyTesting: ["DemoTests/FooTests/testA"],
            simulatorID: nil,
            metadata: [:],
            wait: false
        )
        let job = JobRecord(
            id: "job-123",
            project: "demo",
            state: .queued,
            resultClass: nil,
            request: request,
            summary: nil,
            jobDirectory: temp.appendingPathComponent("job").path,
            createdAt: 0,
            startedAt: nil,
            finishedAt: nil,
            processID: nil,
            simulatorID: nil,
            cancelRequested: false
        )
        let paths = ExecutionPaths(job: job)
        try paths.createDirectories(using: LocalFileSystem())
        let profile = manualShardBoundaryProfile(repoRoot: temp.appendingPathComponent("repo").path)
        let context = ToolExecutionContext(profile: profile, jobID: job.id, store: store)
        let runtime = FakeManualShardRuntime(fileSystem: LocalFileSystem())

        let result = try ManualShardRunner(
            environment: environment,
            runtime: runtime,
            resultReporter: ResultReporter(environment: environment)
        ).run(
            primarySimulatorID: "SIM-123",
            paths: paths,
            request: request,
            context: context
        )

        XCTAssertEqual(result.resultClass, .success)
        XCTAssertEqual(result.counts?.testsRun, 1)
        XCTAssertEqual(result.shardReports.count, 1)
        XCTAssertTrue(runtime.runAndLogArguments.contains { $0.contains("-only-testing:DemoTests/FooTests/testA") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.shardsManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.combinedSummary.path))
        let junit = try String(contentsOf: paths.junitReport)
        let suiteLine = try XCTUnwrap(junit.split(separator: "\n").first { $0.contains("<testsuite") })
        XCTAssertTrue(suiteLine.contains("time=\"5.000\""))
    }
}

private final class StickyManualShardClock: Clock {
    private let lock = NSLock()
    private let start: TimeInterval
    private let later: TimeInterval
    private var hasReturnedStart = false

    init(start: TimeInterval, later: TimeInterval) {
        self.start = start
        self.later = later
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        if hasReturnedStart {
            return Date(timeIntervalSince1970: later)
        }
        hasReturnedStart = true
        return Date(timeIntervalSince1970: start)
    }
}

private final class ManualShardXCResultToolRunner: ToolRunning {
    func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)?
    ) throws -> ToolResult {
        if arguments.contains("summary") {
            return ToolResult(exitCode: 0, output: #"{"totalTestCount":1,"failedTests":0,"skippedTests":0}"#, timedOut: false)
        }
        if arguments.contains("tests") {
            return ToolResult(exitCode: 0, output: #"{"tests":[{"identifier":"DemoTests/FooTests/testA","duration":0.1}]}"#, timedOut: false)
        }
        return ToolResult(exitCode: 0, output: "", timedOut: false)
    }
}

private final class FakeManualShardRuntime: ManualShardRuntime {
    private let fileSystem: FileSystem
    var runAndLogArguments: [String] = []

    init(fileSystem: FileSystem) {
        self.fileSystem = fileSystem
    }

    func resolveTestProductReference(
        in paths: ExecutionPaths,
        preferredTestPlan: String?,
        context: ToolExecutionContext
    ) -> TestProductReference? {
        .xctestrun(URL(fileURLWithPath: "/tmp/Demo.xctestrun"))
    }

    func missingTestProductReferenceMessage(paths: ExecutionPaths, context: ToolExecutionContext) -> String {
        "missing test products"
    }

    func failAndLog(message: String, exitCode: Int32, logURL: URL, combinedLog: URL) throws -> ToolResult {
        try fileSystem.appendData(Data(message.utf8), to: logURL)
        try fileSystem.appendData(Data(message.utf8), to: combinedLog)
        return ToolResult(exitCode: exitCode, output: message, timedOut: false)
    }

    func warnAndLog(message: String, logURL: URL, combinedLog: URL) throws {
        try fileSystem.appendData(Data(message.utf8), to: logURL)
        try fileSystem.appendData(Data(message.utf8), to: combinedLog)
    }

    func runTool(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        environmentOverrides: [String: String]
    ) throws -> ToolResult {
        ToolResult(exitCode: 0, output: "", timedOut: false)
    }

    func runAndLog(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext,
        environmentOverrides: [String: String]
    ) throws -> ToolResult {
        try runAndLog(
            tool: tool,
            arguments: arguments,
            timeout: timeout,
            logURL: logURL,
            combinedLog: combinedLog,
            context: context,
            environmentOverrides: environmentOverrides,
            processStarted: nil
        )
    }

    func runAndLog(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext,
        environmentOverrides: [String: String],
        processStarted: ((Int32) throws -> Void)?
    ) throws -> ToolResult {
        try processStarted?(Int32(runAndLogArguments.count + 1))
        runAndLogArguments.append(arguments.joined(separator: " "))
        if let resultBundlePath = argument(after: "-resultBundlePath", in: arguments) {
            try fileSystem.createDirectory(URL(fileURLWithPath: resultBundlePath))
        }
        try fileSystem.appendData(Data("test output\n".utf8), to: logURL)
        try fileSystem.appendData(Data("test output\n".utf8), to: combinedLog)
        return ToolResult(exitCode: 0, output: "test output\n", timedOut: false)
    }

    func throwIfCanceled(_ result: ToolResult, context: ToolExecutionContext) throws {}

    func isCancellationResult(_ result: ToolResult) -> Bool {
        false
    }

    func commandFailed(_ message: String, output: String) -> XCStewardError {
        .commandFailed(output.isEmpty ? message : "\(message): \(output)")
    }

    func shouldRetryBootstrapFailure(run: ToolResult) -> Bool {
        false
    }

    func classify(run: ToolResult, resultBundle: URL) -> TestOutcome {
        TestOutcome(
            resultClass: fileSystem.fileExists(resultBundle) ? .success : .artifactFailure,
            exitCode: run.exitCode
        )
    }

    func prepareSimulatorPrivacy(
        simulatorID: String,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext
    ) throws {}

    func prepareResultStreamIfNeeded(for settings: ResultStreamSettings, path: URL) throws {
        if settings.enabled {
            try fileSystem.writeData(Data(), to: path)
        }
    }

    func captureSimulatorDiagnostics(
        simulatorID: String,
        outputURL: URL,
        context: ToolExecutionContext
    ) -> String? {
        nil
    }

    func cleanupSimulatorAfterJob(simulatorID: String, context: ToolExecutionContext) {}

    func bootSimulator(simulatorID: String, context: ToolExecutionContext) throws {}

    func shutdownSimulatorForCloneTemplate(simulatorID: String, context: ToolExecutionContext) throws {}

    func cloneManagedShardSimulator(
        templateSimulatorID: String,
        managed: ManagedSimulator,
        shardIndex: Int,
        context: ToolExecutionContext
    ) throws -> String {
        "00000000-0000-0000-0000-000000000456"
    }

    func recoverSimulatorForShardRetry(simulatorID: String, context: ToolExecutionContext) throws {}

    func deleteTransientSimulatorAfterJob(simulatorID: String, context: ToolExecutionContext) {}

    func testRunnerEnvironment(
        context: ToolExecutionContext,
        temporaryDirectory: URL,
        phase: String,
        shardID: String?,
        shardIndex: Int?,
        totalShards: Int?
    ) -> [String: String] {
        ["TMPDIR": temporaryDirectory.path]
    }

    func testIdentifier(_ identifier: String, matchesSkipFilter skipFilter: String) -> Bool {
        identifier == skipFilter || identifier.hasPrefix("\(skipFilter)/")
    }

    func parseCreatedSimulatorID(from output: String) -> String? {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
}

private func manualShardBoundaryProfile(repoRoot: String) -> ProjectProfile {
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
        parallel: ParallelSettings(mode: .manualShards, maxWorkers: 1, exactWorkers: false, shardCount: 1),
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
