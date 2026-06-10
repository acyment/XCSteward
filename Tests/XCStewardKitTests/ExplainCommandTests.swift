// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest
@testable import XCStewardKit

final class ExplainCommandTests: XCTestCase {
    func testExplainJSONSummarizesTestFailureEvidence() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let jobID = "test-failure-job"
        let jobDirectory = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let combinedLog = jobDirectory.appendingPathComponent("logs/combined.log")
        let buildLog = jobDirectory.appendingPathComponent("logs/build.log")
        let testLog = jobDirectory.appendingPathComponent("logs/test.log")
        let junit = jobDirectory.appendingPathComponent("artifacts/junit.xml")
        try writeText("combined line 1\ncombined line 2\n", to: combinedLog)
        try writeText("build succeeded\n", to: buildLog)
        try writeText("test output\nAssertion failed\n", to: testLog)
        try writeText(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuite name="Demo" tests="2" failures="1" errors="0" skipped="0">
              <testcase classname="DemoTests.FooTests" name="testBreaks" time="0.1">
                <failure message="Expected true">Expected true</failure>
              </testcase>
              <testcase classname="DemoTests.FooTests" name="testPasses" time="0.1" />
            </testsuite>
            """,
            to: junit
        )
        let artifacts = JobArtifacts(
            xcresult: jobDirectory.appendingPathComponent("artifacts/result.xcresult").path,
            combinedLog: combinedLog.path,
            buildLog: buildLog.path,
            testLog: testLog.path,
            derivedData: jobDirectory.appendingPathComponent("derived-data").path,
            diagnostics: nil,
            junit: junit.path,
            commandEvents: nil
        )
        let summary = jobSummary(
            jobID: jobID,
            jobDirectory: jobDirectory,
            resultClass: .testFailure,
            exitCode: 10,
            counts: JobCounts(testsRun: 2, testsFailed: 1, testsSkipped: 0),
            artifacts: artifacts,
            summaryLine: "Tests failed"
        )
        try seedJob(stateRoot: stateRoot, jobID: jobID, jobDirectory: jobDirectory, summary: summary)

        let result = try runCLI(arguments: ["explain", "--state-root", stateRoot.path, jobID, "--json"])

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stderr, "")
        let document = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(document["schema_version"] as? Int, 1)
        XCTAssertEqual(document["job_id"] as? String, jobID)
        XCTAssertEqual(document["result_class"] as? String, "test_failure")
        XCTAssertEqual(document["recommended_action"] as? String, "Inspect failed tests, JUnit, .xcresult, and test log; do not blind-retry.")
        let retryPolicy = try XCTUnwrap(document["retry_policy"] as? [String: Any])
        XCTAssertEqual(retryPolicy["auto_retry"] as? Bool, false)
        XCTAssertEqual(retryPolicy["max_auto_retries"] as? Int, 0)

        let failedTests = try XCTUnwrap(document["failed_tests"] as? [[String: Any]])
        XCTAssertEqual(failedTests.count, 1)
        XCTAssertEqual(failedTests[0]["class_name"] as? String, "DemoTests.FooTests")
        XCTAssertEqual(failedTests[0]["name"] as? String, "testBreaks")
        XCTAssertEqual(failedTests[0]["failure_kind"] as? String, "failure")
        XCTAssertEqual(failedTests[0]["message"] as? String, "Expected true")

        let logExcerpts = try XCTUnwrap(document["log_excerpts"] as? [[String: Any]])
        let testExcerpt = try XCTUnwrap(logExcerpts.first { $0["source"] as? String == "test_log" })
        XCTAssertTrue((testExcerpt["excerpt"] as? String)?.contains("Assertion failed") == true)
    }

    func testExplainJSONSummarizesBuildIssues() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let jobID = "build-failure-job"
        let jobDirectory = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let combinedLog = jobDirectory.appendingPathComponent("logs/combined.log")
        let buildLog = jobDirectory.appendingPathComponent("logs/build.log")
        try writeText("combined build failure\n", to: combinedLog)
        try writeText(
            """
            Compile Swift
            /repo/App/Foo.swift:12:8: error: cannot find 'bar' in scope
            Build failed
            """,
            to: buildLog
        )
        let artifacts = JobArtifacts(
            xcresult: nil,
            combinedLog: combinedLog.path,
            buildLog: buildLog.path,
            testLog: nil,
            derivedData: nil,
            diagnostics: nil,
            junit: nil,
            commandEvents: nil
        )
        let summary = jobSummary(
            jobID: jobID,
            jobDirectory: jobDirectory,
            resultClass: .buildFailure,
            exitCode: 10,
            counts: nil,
            artifacts: artifacts,
            summaryLine: "Build failed"
        )
        try seedJob(stateRoot: stateRoot, jobID: jobID, jobDirectory: jobDirectory, summary: summary)

        let result = try runCLI(arguments: ["explain", "--state-root", stateRoot.path, jobID, "--json"])

        XCTAssertEqual(result.status, 0)
        let document = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(document["recommended_action"] as? String, "Inspect build issues and build log; do not blind-retry.")
        let buildIssues = try XCTUnwrap(document["build_issues"] as? [[String: Any]])
        XCTAssertEqual(buildIssues.count, 2)
        XCTAssertEqual(buildIssues[0]["line_number"] as? Int, 2)
        XCTAssertTrue((buildIssues[0]["text"] as? String)?.contains("cannot find 'bar'") == true)
    }

    func testExplainJSONHandlesQueuedJob() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let jobID = "queued-job"
        let jobDirectory = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let request = JobRequest(project: "demo", testPlan: nil, onlyTesting: [], simulatorID: nil, metadata: [:], wait: false)
        let record = JobRecord(
            id: jobID,
            project: "demo",
            state: .queued,
            resultClass: nil,
            request: request,
            summary: nil,
            jobDirectory: jobDirectory.path,
            createdAt: 1,
            startedAt: nil,
            finishedAt: nil,
            processID: nil,
            simulatorID: nil,
            cancelRequested: false
        )
        try seedJob(stateRoot: stateRoot, record: record)

        let result = try runCLI(arguments: ["explain", "--state-root", stateRoot.path, jobID, "--json"])

        XCTAssertEqual(result.status, 0)
        let document = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(document["state"] as? String, "queued")
        XCTAssertEqual(document["recommended_action"] as? String, "Wait for the job to finish, then run explain again.")
        let retryPolicy = try XCTUnwrap(document["retry_policy"] as? [String: Any])
        XCTAssertEqual(retryPolicy["auto_retry"] as? Bool, false)
        XCTAssertEqual((document["failed_tests"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((document["log_excerpts"] as? [[String: Any]])?.count, 0)
    }

    private func jobSummary(
        jobID: String,
        jobDirectory: URL,
        resultClass: ResultClass,
        exitCode: Int32,
        counts: JobCounts?,
        artifacts: JobArtifacts,
        summaryLine: String
    ) -> JobSummary {
        JobSummary(
            jobID: jobID,
            project: "demo",
            state: .failed,
            resultClass: resultClass,
            exitCode: exitCode,
            submittedAt: 1,
            startedAt: 2,
            finishedAt: 3,
            durationSeconds: 1,
            testPlan: nil,
            onlyTesting: [],
            simulatorID: "SIM-123",
            counts: counts,
            artifacts: artifacts,
            summaryLine: summaryLine,
            metadata: [:]
        )
    }

    private func seedJob(
        stateRoot: URL,
        jobID: String,
        jobDirectory: URL,
        summary: JobSummary
    ) throws {
        let request = JobRequest(project: "demo", testPlan: nil, onlyTesting: [], simulatorID: nil, metadata: [:], wait: false)
        let record = JobRecord(
            id: jobID,
            project: "demo",
            state: summary.state,
            resultClass: summary.resultClass,
            request: request,
            summary: summary,
            jobDirectory: jobDirectory.path,
            createdAt: summary.submittedAt,
            startedAt: summary.startedAt,
            finishedAt: summary.finishedAt,
            processID: nil,
            simulatorID: summary.simulatorID,
            cancelRequested: false
        )
        try seedJob(stateRoot: stateRoot, record: record)
    }

    private func seedJob(stateRoot: URL, record: JobRecord) throws {
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        try store.createJob(record)
    }
}
