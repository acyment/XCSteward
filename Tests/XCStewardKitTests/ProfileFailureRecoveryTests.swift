// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest
@testable import XCStewardKit

final class ProfileFailureRecoveryTests: XCTestCase {
    func testMissingRepoRootFailsBeforeToolOrSimulatorMutationWithEvidence() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let missingRepoRoot = temp.appendingPathComponent("missing-parent/missing-repo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRepoRoot.path))
        try writeText(
            """
            repo_root = "\(missingRepoRoot.path)"
            project_path = "Demo.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """,
            to: stateRoot.appendingPathComponent("projects/missing-repo.toml")
        )

        let runner = RecordingToolRunner()
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: ProfileFailureTestProcessInfo(),
            toolRunner: runner
        )
        let loadedProfile = try ProfileLoader(environment: environment).loadProfile(named: "missing-repo")
        XCTAssertEqual(loadedProfile.repoRoot, missingRepoRoot.path)
        XCTAssertFalse(environment.fileSystem.fileExists(URL(fileURLWithPath: loadedProfile.repoRoot)))
        let store = try StateStore(environment: environment)
        let jobID = "missing-repo"
        try store.createJob(JobRecord(
            id: jobID,
            project: "missing-repo",
            state: .queued,
            resultClass: nil,
            request: JobRequest(
                project: "missing-repo",
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

        XCTAssertFalse(
            runner.invocations.contains { invocation in
                invocation.tool == "xcrun"
                    || invocation.tool == "xcodebuild"
                    || invocation.arguments.contains("simctl")
            },
            "\(runner.invocations)"
        )
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
        let job = try XCTUnwrap(store.fetchJob(id: jobID))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.resultClass, .runnerBootstrapFailure)
        XCTAssertNil(job.processID)

        let summary = try XCTUnwrap(job.summary)
        XCTAssertEqual(summary.state, .failed)
        XCTAssertEqual(summary.resultClass, .runnerBootstrapFailure)
        XCTAssertTrue(summary.summaryLine.contains("repo_root is not an accessible directory"))
        XCTAssertNil(summary.artifacts.xcresult)
        XCTAssertNotNil(summary.artifacts.combinedLog)

        let jobDirectory = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let summaryURL = jobDirectory.appendingPathComponent("artifacts/summary.json")
        let persistedSummary = try decodeJSON(JobSummary.self, from: Data(contentsOf: summaryURL))
        XCTAssertEqual(persistedSummary.summaryLine, summary.summaryLine)
        XCTAssertNil(persistedSummary.artifacts.xcresult)

        let combinedLog = try String(contentsOf: jobDirectory.appendingPathComponent("logs/combined.log"))
        XCTAssertTrue(combinedLog.contains("repo_root is not an accessible directory"))

        let runMetadata = try XCTUnwrap(
            parseJSON(String(contentsOf: jobDirectory.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any]
        )
        XCTAssertEqual(runMetadata["state"] as? String, "failed")
        XCTAssertEqual(runMetadata["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(runMetadata["project"] as? String, "missing-repo")
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        XCTAssertEqual(profileMetadata["repo_root"] as? String, missingRepoRoot.path)
        XCTAssertEqual((runMetadata["commands"] as? [Any])?.count, 0)
    }

    func testMissingProfileFailsAsRunnerBootstrapFailureWithEvidence() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let runner = RecordingToolRunner()
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: ProfileFailureTestProcessInfo(),
            toolRunner: runner
        )
        let store = try StateStore(environment: environment)
        let jobID = "missing-profile"
        try store.createJob(JobRecord(
            id: jobID,
            project: "does-not-exist",
            state: .queued,
            resultClass: nil,
            request: JobRequest(
                project: "does-not-exist",
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

        XCTAssertFalse(
            runner.invocations.contains { invocation in
                invocation.tool == "xcrun"
                    || invocation.tool == "xcodebuild"
                    || invocation.arguments.contains("simctl")
            },
            "\(runner.invocations)"
        )
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
        let job = try XCTUnwrap(store.fetchJob(id: jobID))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.resultClass, .runnerBootstrapFailure)
        XCTAssertNil(job.processID)
        XCTAssertNil(job.simulatorID)

        let summary = try XCTUnwrap(job.summary)
        XCTAssertEqual(summary.resultClass, .runnerBootstrapFailure)
        XCTAssertTrue(summary.summaryLine.contains("Profile 'does-not-exist' not found"))
        XCTAssertNil(summary.artifacts.xcresult)

        let jobDirectory = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let persistedSummary = try decodeJSON(
            JobSummary.self,
            from: Data(contentsOf: jobDirectory.appendingPathComponent("artifacts/summary.json"))
        )
        XCTAssertEqual(persistedSummary.resultClass, .runnerBootstrapFailure)

        let runMetadata = try XCTUnwrap(
            parseJSON(String(contentsOf: jobDirectory.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any]
        )
        XCTAssertEqual(runMetadata["state"] as? String, "failed")
        XCTAssertEqual(runMetadata["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(runMetadata["project"] as? String, "does-not-exist")
        XCTAssertTrue((runMetadata["error"] as? String)?.contains("Profile 'does-not-exist' not found") == true)
        XCTAssertEqual((runMetadata["commands"] as? [Any])?.count, 0)
    }

    func testMalformedProfileFailsBeforeToolOrSimulatorMutationWithEvidence() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try writeText(
            """
            repo_root = "\(repoRoot.path)"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """,
            to: stateRoot.appendingPathComponent("projects/malformed.toml")
        )

        let runner = RecordingToolRunner()
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: ProfileFailureTestProcessInfo(),
            toolRunner: runner
        )
        let store = try StateStore(environment: environment)
        let jobID = "malformed-profile"
        try store.createJob(JobRecord(
            id: jobID,
            project: "malformed",
            state: .queued,
            resultClass: nil,
            request: JobRequest(
                project: "malformed",
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

        XCTAssertFalse(
            runner.invocations.contains { invocation in
                invocation.tool == "xcrun"
                    || invocation.tool == "xcodebuild"
                    || invocation.arguments.contains("simctl")
            },
            "\(runner.invocations)"
        )
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
        let job = try XCTUnwrap(store.fetchJob(id: jobID))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.resultClass, .runnerBootstrapFailure)
        XCTAssertNil(job.processID)
        XCTAssertNil(job.simulatorID)

        let summary = try XCTUnwrap(job.summary)
        XCTAssertEqual(summary.state, .failed)
        XCTAssertEqual(summary.resultClass, .runnerBootstrapFailure)
        XCTAssertTrue(summary.summaryLine.contains("must set exactly one of project_path or workspace_path"))
        XCTAssertNil(summary.artifacts.xcresult)
        XCTAssertNotNil(summary.artifacts.combinedLog)

        let jobDirectory = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let summaryURL = jobDirectory.appendingPathComponent("artifacts/summary.json")
        let persistedSummary = try decodeJSON(JobSummary.self, from: Data(contentsOf: summaryURL))
        XCTAssertEqual(persistedSummary.summaryLine, summary.summaryLine)
        XCTAssertNil(persistedSummary.artifacts.xcresult)

        let combinedLog = try String(contentsOf: jobDirectory.appendingPathComponent("logs/combined.log"))
        XCTAssertTrue(combinedLog.contains("must set exactly one of project_path or workspace_path"))

        let runMetadata = try XCTUnwrap(
            parseJSON(String(contentsOf: jobDirectory.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any]
        )
        XCTAssertEqual(runMetadata["state"] as? String, "failed")
        XCTAssertEqual(runMetadata["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(runMetadata["project"] as? String, "malformed")
        XCTAssertTrue((runMetadata["error"] as? String)?.contains("must set exactly one of project_path or workspace_path") == true)
        XCTAssertEqual((runMetadata["commands"] as? [Any])?.count, 0)
        XCTAssertTrue(runMetadata["simulator_id"] == nil || runMetadata["simulator_id"] is NSNull)
    }

    func testWrongTypedProfileValueFailsBeforeToolOrSimulatorMutationWithEvidence() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try writeText(
            """
            repo_root = "\(repoRoot.path)"
            project_path = "Demo.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"

            [parallel]
            max_workers = "one"
            """,
            to: stateRoot.appendingPathComponent("projects/wrong-type.toml")
        )

        let runner = RecordingToolRunner()
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: ProfileFailureTestProcessInfo(),
            toolRunner: runner
        )
        let store = try StateStore(environment: environment)
        let jobID = "wrong-typed-profile"
        try store.createJob(JobRecord(
            id: jobID,
            project: "wrong-type",
            state: .queued,
            resultClass: nil,
            request: JobRequest(
                project: "wrong-type",
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

        XCTAssertFalse(
            runner.invocations.contains { invocation in
                invocation.tool == "xcrun"
                    || invocation.tool == "xcodebuild"
                    || invocation.arguments.contains("simctl")
            },
            "\(runner.invocations)"
        )
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
        let job = try XCTUnwrap(store.fetchJob(id: jobID))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.resultClass, .runnerBootstrapFailure)
        XCTAssertNil(job.processID)
        XCTAssertNil(job.simulatorID)

        let summary = try XCTUnwrap(job.summary)
        XCTAssertEqual(summary.resultClass, .runnerBootstrapFailure)
        XCTAssertTrue(summary.summaryLine.contains("parallel.max_workers must be an integer"))
        XCTAssertNil(summary.artifacts.xcresult)

        let jobDirectory = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let combinedLog = try String(contentsOf: jobDirectory.appendingPathComponent("logs/combined.log"))
        XCTAssertTrue(combinedLog.contains("parallel.max_workers must be an integer"))

        let runMetadata = try XCTUnwrap(
            parseJSON(String(contentsOf: jobDirectory.appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any]
        )
        XCTAssertEqual(runMetadata["state"] as? String, "failed")
        XCTAssertEqual(runMetadata["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(runMetadata["project"] as? String, "wrong-type")
        XCTAssertTrue((runMetadata["error"] as? String)?.contains("parallel.max_workers must be an integer") == true)
        XCTAssertEqual((runMetadata["commands"] as? [Any])?.count, 0)
        XCTAssertTrue(runMetadata["simulator_id"] == nil || runMetadata["simulator_id"] is NSNull)
    }
}

private struct ProfileFailureTestProcessInfo: ProcessInfoProviding {
    var environment: [String: String] = [:]
    var arguments: [String] = []
}

private final class RecordingToolRunner: ToolRunning {
    private(set) var invocations: [(tool: String, arguments: [String])] = []

    func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)?
    ) throws -> ToolResult {
        invocations.append((tool: tool, arguments: arguments))
        return ToolResult(exitCode: 0, output: "  PID COMMAND\n", timedOut: false)
    }
}
