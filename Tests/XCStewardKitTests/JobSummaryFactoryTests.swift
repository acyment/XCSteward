import XCTest
@testable import XCStewardKit

final class JobSummaryFactoryTests: XCTestCase {
    func testQueuedCanceledSummaryUsesEmptyArtifactsAndStablePolicy() {
        let job = summaryFactoryJob(state: .queued, startedAt: nil)

        let summary = JobSummaryFactory().queuedCanceledSummary(job: job, finishedAt: 42)

        XCTAssertEqual(summary.jobID, "job-1")
        XCTAssertEqual(summary.state, .canceled)
        XCTAssertEqual(summary.resultClass, .canceled)
        XCTAssertNil(summary.startedAt)
        XCTAssertEqual(summary.finishedAt, 42)
        XCTAssertEqual(summary.durationSeconds, 0)
        XCTAssertEqual(summary.testPlan, "Smoke")
        XCTAssertEqual(summary.onlyTesting, ["AppTests/FooTests"])
        XCTAssertEqual(summary.metadata, ["commit": "abc"])
        XCTAssertEqual(summary.summaryLine, "Canceled")
        XCTAssertNil(summary.artifacts.xcresult)
        XCTAssertNil(summary.artifacts.combinedLog)
        XCTAssertNil(summary.artifacts.junit)
    }

    func testRunningCanceledSummaryKeepsStartedAtAndDuration() {
        let job = summaryFactoryJob(state: .running, startedAt: 10, simulatorID: "SIM-1")

        let summary = JobSummaryFactory().canceledSummary(
            job: job,
            finishedAt: 25,
            startedAt: job.startedAt,
            durationSeconds: 15
        )

        XCTAssertEqual(summary.state, .canceled)
        XCTAssertEqual(summary.startedAt, 10)
        XCTAssertEqual(summary.finishedAt, 25)
        XCTAssertEqual(summary.durationSeconds, 15)
        XCTAssertEqual(summary.simulatorID, "SIM-1")
    }

    func testInternalFailureSummaryUsesDefaultArtifactPathsAndErrorText() {
        let job = summaryFactoryJob(state: .running, startedAt: 12, jobDirectory: "/tmp/xcsteward/job-1")

        let summary = JobSummaryFactory().internalFailureSummary(
            job: job,
            error: SummaryFactoryError.example,
            finishedAt: 20
        )

        XCTAssertEqual(summary.state, .failed)
        XCTAssertEqual(summary.resultClass, .internalError)
        XCTAssertEqual(summary.startedAt, 12)
        XCTAssertEqual(summary.durationSeconds, 8)
        XCTAssertEqual(summary.summaryLine, "example failure")
        XCTAssertEqual(summary.artifacts.xcresult, "/tmp/xcsteward/job-1/artifacts/result.xcresult")
        XCTAssertEqual(summary.artifacts.combinedLog, "/tmp/xcsteward/job-1/logs/combined.log")
        XCTAssertEqual(summary.artifacts.derivedData, "/tmp/xcsteward/job-1/derived-data")
    }

    func testFallbackSummaryMirrorsJobStateAndDefaultArtifacts() {
        let job = summaryFactoryJob(
            state: .interrupted,
            resultClass: .internalError,
            startedAt: 2,
            finishedAt: 5,
            jobDirectory: "/tmp/xcsteward/job-2"
        )

        let summary = JobSummaryFactory().fallbackSummary(job: job)

        XCTAssertEqual(summary.state, .interrupted)
        XCTAssertEqual(summary.resultClass, .internalError)
        XCTAssertEqual(summary.startedAt, 2)
        XCTAssertEqual(summary.finishedAt, 5)
        XCTAssertNil(summary.durationSeconds)
        XCTAssertEqual(summary.summaryLine, "Interrupted")
        XCTAssertEqual(summary.artifacts.testLog, "/tmp/xcsteward/job-2/logs/test.log")
    }
}

private enum SummaryFactoryError: Error, CustomStringConvertible {
    case example

    var description: String {
        "example failure"
    }
}

private func summaryFactoryJob(
    state: JobState,
    resultClass: ResultClass? = nil,
    startedAt: Double?,
    finishedAt: Double? = nil,
    simulatorID: String? = nil,
    jobDirectory: String = "/tmp/job-1"
) -> JobRecord {
    let request = JobRequest(
        project: "demo",
        testPlan: "Smoke",
        onlyTesting: ["AppTests/FooTests"],
        simulatorID: simulatorID,
        metadata: ["commit": "abc"],
        wait: false
    )
    return JobRecord(
        id: "job-1",
        project: "demo",
        state: state,
        resultClass: resultClass,
        request: request,
        summary: nil,
        jobDirectory: jobDirectory,
        createdAt: 1,
        startedAt: startedAt,
        finishedAt: finishedAt,
        processID: nil,
        simulatorID: simulatorID,
        cancelRequested: false
    )
}
