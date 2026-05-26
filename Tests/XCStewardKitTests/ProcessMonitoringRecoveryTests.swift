import Foundation
import XCTest
@testable import XCStewardKit

final class ProcessMonitoringRecoveryTests: XCTestCase {
    func testWorkerRecordsInternalFailureWhenBuildProcessMonitoringFails() throws {
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

        let runner = ProcessMonitoringFailureToolRunner()
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: ProcessMonitoringTestProcessInfo(environment: [
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ]),
            toolRunner: runner
        )
        let store = try StateStore(environment: environment)
        let jobID = "process-monitoring-failure"
        try store.createJob(JobRecord(
            id: jobID,
            project: "demo",
            state: .queued,
            resultClass: nil,
            request: JobRequest(
                project: "demo",
                testPlan: nil,
                onlyTesting: [],
                simulatorID: nil,
                metadata: [:],
                wait: false
            ),
            summary: nil,
            jobDirectory: stateRoot.appendingPathComponent("jobs/\(jobID)").path,
            createdAt: 1,
            startedAt: nil,
            finishedAt: nil,
            processID: nil,
            simulatorID: nil,
            cancelRequested: false
        ))

        try Worker(environment: environment, store: store).run()

        let job = try XCTUnwrap(store.fetchJob(id: jobID))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.resultClass, .internalError)
        XCTAssertNil(job.processID)
        XCTAssertEqual(job.simulatorID, "SIM-123")
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)

        let summary = try XCTUnwrap(job.summary)
        XCTAssertEqual(summary.state, .failed)
        XCTAssertEqual(summary.resultClass, .internalError)
        XCTAssertTrue(summary.summaryLine.contains("Unable to monitor process 4242"))
        XCTAssertTrue(summary.artifacts.xcresult == nil)
        XCTAssertNotNil(summary.artifacts.combinedLog)
        XCTAssertNotNil(summary.artifacts.buildLog)

        let jobDirectory = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let buildLog = try String(contentsOf: jobDirectory.appendingPathComponent("logs/build.log"))
        let combinedLog = try String(contentsOf: jobDirectory.appendingPathComponent("logs/combined.log"))
        XCTAssertTrue(buildLog.contains("Unable to monitor process 4242"))
        XCTAssertTrue(combinedLog.contains("Unable to monitor process 4242"))

        let runMetadata = try XCTUnwrap(
            parseJSON(String(contentsOf: jobDirectory.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any]
        )
        XCTAssertEqual(runMetadata["state"] as? String, "failed")
        XCTAssertEqual(runMetadata["result_class"] as? String, "internal_error")
        XCTAssertEqual(runMetadata["simulator_id"] as? String, "SIM-123")
        XCTAssertEqual(runMetadata["result_bundle_path"] == nil || runMetadata["result_bundle_path"] is NSNull, true)

        let commands = try XCTUnwrap(runMetadata["commands"] as? [[String: Any]])
        let buildCommand = try XCTUnwrap(
            commands.first { ($0["phase"] as? String) == "build" && ($0["tool"] as? String) == "xcodebuild" },
            "\(commands)"
        )
        XCTAssertTrue((buildCommand["error"] as? String)?.contains("Unable to monitor process 4242") == true)
        XCTAssertFalse(commands.contains { ($0["phase"] as? String) == "test" && ($0["tool"] as? String) == "xcodebuild" })
    }
}

private struct ProcessMonitoringTestProcessInfo: ProcessInfoProviding {
    var environment: [String: String]
    var arguments: [String] = []
}

private final class ProcessMonitoringFailureToolRunner: ToolRunning {
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
        if tool == "xcrun", arguments == ["--find", "xcodebuild"] {
            return ToolResult(exitCode: 0, output: "/tmp/fake-xcodebuild\n", timedOut: false)
        }
        if tool == "xcrun", arguments == ["simctl", "list", "devices", "--json"] {
            return ToolResult(
                exitCode: 0,
                output: #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"iPhone 17 Pro","udid":"SIM-123","state":"Shutdown","isAvailable":true}]}}"#,
                timedOut: false
            )
        }
        if tool == "xcrun", arguments.starts(with: ["simctl", "boot"]) {
            return ToolResult(exitCode: 0, output: "", timedOut: false)
        }
        if tool == "xcrun", arguments.starts(with: ["simctl", "bootstatus"]) {
            return ToolResult(exitCode: 0, output: "", timedOut: false)
        }
        if tool == "xcodebuild", arguments == ["-help"] {
            return ToolResult(exitCode: 0, output: "-parallel-testing-enabled\n", timedOut: false)
        }
        if tool == "xcodebuild", arguments == ["-version"] {
            return ToolResult(exitCode: 0, output: "Xcode 16.4\nBuild version 16F6\n", timedOut: false)
        }
        if tool == "xcodebuild", arguments.contains("build-for-testing") {
            try processStarted?(4242)
            throw XCStewardError.commandFailed("Unable to monitor process 4242: No child processes")
        }
        return ToolResult(exitCode: 99, output: "Unexpected \(tool) \(arguments.joined(separator: " "))\n", timedOut: false)
    }
}
