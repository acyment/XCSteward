import Foundation
import XCTest
@testable import XCStewardKit

final class ExecutorCancellationRaceTests: XCTestCase {
    func testCancelRequestedAfterBuildFailureDoesNotMaskBuildFailure() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)

        let jobID = "cancel-race-build-failure"
        let runner = BuildFailureCancelRaceToolRunner(jobID: jobID)
        let environment = AppEnvironment(paths: AppPaths(stateRoot: stateRoot), toolRunner: runner)
        let store = try StateStore(environment: environment)
        runner.store = store

        let request = JobRequest(project: "demo", testPlan: nil, onlyTesting: [], simulatorID: nil, metadata: [:], wait: true)
        let job = JobRecord(
            id: jobID,
            project: "demo",
            state: .queued,
            resultClass: nil,
            request: request,
            summary: nil,
            jobDirectory: stateRoot.appendingPathComponent("jobs/\(jobID)").path,
            createdAt: 1,
            startedAt: nil,
            finishedAt: nil,
            processID: nil,
            simulatorID: nil,
            cancelRequested: false
        )
        try store.createJob(job)
        let profile = ProjectProfile(
            name: "demo",
            repoRoot: repoRoot.path,
            projectPath: "App.xcodeproj",
            workspacePath: nil,
            scheme: "Demo",
            defaultSimulatorID: "SIM-123",
            managedSimulator: nil,
            defaultTestPlan: nil,
            allowedSimulatorIDs: [],
            env: [:],
            timeouts: Timeouts(boot: 1, build: 1, test: 1),
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

        let summary = try JobExecutor(environment: environment).execute(job: job, profile: profile, store: store)

        XCTAssertEqual(summary.state, .failed)
        XCTAssertEqual(summary.resultClass, .buildFailure)
        XCTAssertEqual(summary.summaryLine, "Build failed")
        XCTAssertEqual(try store.fetchJob(id: jobID)?.cancelRequested, true)
    }
}

private final class BuildFailureCancelRaceToolRunner: ToolRunning {
    let jobID: String
    var store: StateStore?

    init(jobID: String) {
        self.jobID = jobID
    }

    func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)?
    ) throws -> ToolResult {
        try processStarted?(4242)
        if tool == "ps" {
            return ToolResult(exitCode: 0, output: "  PID COMMAND\n", timedOut: false)
        }
        if tool == "xcrun", arguments.starts(with: ["simctl", "boot"]) || arguments.starts(with: ["simctl", "bootstatus"]) {
            return ToolResult(exitCode: 0, output: "", timedOut: false)
        }
        if tool == "xcodebuild", arguments.contains("build-for-testing") {
            try store?.requestCancel(jobID: jobID)
            return ToolResult(exitCode: 65, output: "Build failed\n", timedOut: false)
        }
        return ToolResult(exitCode: 99, output: "Unexpected \(tool) \(arguments.joined(separator: " "))\n", timedOut: false)
    }
}
