import Darwin
import Foundation
import XCTest
@testable import XCStewardKit

final class StateStoreGatewayTests: XCTestCase {
    func testJobGatewayCreatesClaimsAndPatchesJobs() throws {
        let store = try gatewayStore()
        let job = gatewayJob(id: "job-1", state: .queued)

        try store.jobs.create(job)
        let claimed = try XCTUnwrap(store.jobs.claimNextQueued())
        XCTAssertEqual(claimed.id, "job-1")
        XCTAssertEqual(claimed.state, .running)

        let summary = gatewaySummary(job: job, state: .succeeded, resultClass: .success)
        try store.jobs.update(
            id: "job-1",
            patch: JobStatePatch(
                state: .succeeded,
                resultClass: .success,
                summary: summary,
                finishedAt: 10,
                simulatorID: "SIM-123"
            )
        )

        let fetched = try XCTUnwrap(store.jobs.fetch(id: "job-1"))
        XCTAssertEqual(fetched.state, .succeeded)
        XCTAssertEqual(fetched.resultClass, .success)
        XCTAssertEqual(fetched.summary?.summaryLine, "Tests succeeded")
        XCTAssertEqual(fetched.simulatorID, "SIM-123")
    }

    func testConcurrentClaimersOnlyClaimSingleQueuedJobOnce() throws {
        let stateRoot = try makeTempDirectory().appendingPathComponent("state")
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        try store.jobs.create(gatewayJob(id: "job-1", state: .queued))

        let claimed = try claimJobsConcurrently(stateRoot: stateRoot, claimantCount: 16)

        XCTAssertEqual(claimed, ["job-1"])
        let fetched = try XCTUnwrap(store.jobs.fetch(id: "job-1"))
        XCTAssertEqual(fetched.state, .running)
        XCTAssertFalse(try store.hasQueuedJobs())
    }

    func testConcurrentClaimersClaimMultipleQueuedJobsWithoutDuplicates() throws {
        let stateRoot = try makeTempDirectory().appendingPathComponent("state")
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        let jobIDs = (1...5).map { "job-\($0)" }
        for jobID in jobIDs {
            try store.jobs.create(gatewayJob(id: jobID, state: .queued))
        }

        let claimed = try claimJobsConcurrently(stateRoot: stateRoot, claimantCount: 16)

        XCTAssertEqual(Set(claimed), Set(jobIDs))
        XCTAssertEqual(claimed.count, jobIDs.count)
        for jobID in jobIDs {
            let fetched = try XCTUnwrap(store.jobs.fetch(id: jobID))
            XCTAssertEqual(fetched.state, .running)
        }
        XCTAssertFalse(try store.hasQueuedJobs())
    }

    func testWorkerLeaseGatewayRecoversStaleLeaseAndMarksRunningJobsInterrupted() throws {
        let store = try gatewayStore()
        try store.jobs.create(gatewayJob(id: "running-job", state: .running))
        XCTAssertTrue(try store.workerLease.acquire(workerID: "worker-1", pid: 0))

        let recovered = try store.workerLease.recoverStaleIfNeeded()

        XCTAssertTrue(recovered)
        XCTAssertNil(try store.workerLease.current())
        let job = try XCTUnwrap(store.jobs.fetch(id: "running-job"))
        XCTAssertEqual(job.state, .interrupted)
        XCTAssertEqual(job.resultClass, .internalError)
    }

    func testSimulatorLeaseGatewayRecoversStaleAndReleasesByJob() throws {
        let store = try gatewayStore()
        XCTAssertTrue(try store.simulatorLeases.acquire(simulatorID: "SIM-1", jobID: "job-1", pid: getpid()))
        XCTAssertTrue(try store.simulatorLeases.acquire(simulatorID: "SIM-2", jobID: "dead-job", pid: 0))

        let recovered = try store.simulatorLeases.recoverStale()
        XCTAssertEqual(recovered, 1)
        XCTAssertEqual(try store.simulatorLeases.list().map(\.simulatorID), ["SIM-1"])

        try store.simulatorLeases.release(jobID: "job-1")
        XCTAssertTrue(try store.simulatorLeases.list().isEmpty)
    }

    func testTimingGatewayRecordsAndAveragesSamples() throws {
        let store = try gatewayStore()
        try store.timings.record(project: "demo", samples: [
            TestTimingSample(identifier: "DemoTests/FooTests/testA", durationSeconds: 10),
            TestTimingSample(identifier: "  ", durationSeconds: 5),
            TestTimingSample(identifier: "DemoTests/FooTests/testB", durationSeconds: -1),
        ])
        try store.timings.record(project: "demo", samples: [
            TestTimingSample(identifier: "DemoTests/FooTests/testA", durationSeconds: 20),
        ])

        let estimates = try store.timings.estimates(
            project: "demo",
            identifiers: ["DemoTests/FooTests/testA", "DemoTests/FooTests/testB"]
        )

        XCTAssertEqual(estimates["DemoTests/FooTests/testA"], 15)
        XCTAssertNil(estimates["DemoTests/FooTests/testB"])
    }

    func testInfrastructureEventGatewayCountsRecordedAndTerminalInfrastructureFailures() throws {
        let store = try gatewayStore()
        try store.infrastructureEvents.record(
            jobID: "job-1",
            simulatorID: "SIM-1",
            resultClass: .runnerBootstrapFailure,
            message: "retry"
        )
        try store.infrastructureEvents.record(
            jobID: "job-2",
            simulatorID: "SIM-2",
            resultClass: .testFailure,
            message: "assertion"
        )
        let failedJob = gatewayJob(
            id: "failed-job",
            state: .failed,
            resultClass: .artifactFailure,
            finishedAt: Date().timeIntervalSince1970
        )
        try store.jobs.create(failedJob)

        XCTAssertEqual(try store.infrastructureEvents.countRecentFailures(since: 0), 2)
    }
}

private func gatewayStore() throws -> StateStore {
    let temp = try makeTempDirectory()
    return try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: temp.appendingPathComponent("state"))))
}

private func claimJobsConcurrently(stateRoot: URL, claimantCount: Int) throws -> [String] {
    let queue = DispatchQueue(label: "XCStewardTests.StateStore.claimers", attributes: .concurrent)
    let group = DispatchGroup()
    let results = ConcurrentClaimResults()

    for _ in 0..<claimantCount {
        group.enter()
        queue.async {
            defer { group.leave() }
            do {
                let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
                if let job = try store.claimNextQueuedJob() {
                    results.append(job.id)
                }
            } catch {
                results.record(error)
            }
        }
    }

    group.wait()
    if let firstError = results.firstError {
        throw firstError
    }
    return results.claimed.sorted()
}

private final class ConcurrentClaimResults: @unchecked Sendable {
    private let lock = NSLock()
    private var claimedIDs: [String] = []
    private var storedError: Error?

    var claimed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return claimedIDs
    }

    var firstError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func append(_ jobID: String) {
        lock.lock()
        claimedIDs.append(jobID)
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        if storedError == nil {
            storedError = error
        }
        lock.unlock()
    }
}

private func gatewayJob(
    id: String,
    state: JobState,
    resultClass: ResultClass? = nil,
    finishedAt: Double? = nil
) -> JobRecord {
    let request = JobRequest(
        project: "demo",
        testPlan: nil,
        onlyTesting: [],
        simulatorID: nil,
        metadata: [:],
        wait: false
    )
    return JobRecord(
        id: id,
        project: "demo",
        state: state,
        resultClass: resultClass,
        request: request,
        summary: nil,
        jobDirectory: "/tmp/\(id)",
        createdAt: 1,
        startedAt: state == .queued ? nil : 2,
        finishedAt: finishedAt,
        processID: nil,
        simulatorID: nil,
        cancelRequested: false
    )
}

private func gatewaySummary(job: JobRecord, state: JobState, resultClass: ResultClass) -> JobSummary {
    JobSummary(
        jobID: job.id,
        project: job.project,
        state: state,
        resultClass: resultClass,
        exitCode: 0,
        submittedAt: job.createdAt,
        startedAt: 2,
        finishedAt: 10,
        durationSeconds: 8,
        testPlan: nil,
        onlyTesting: [],
        simulatorID: "SIM-123",
        counts: JobCounts(testsRun: 1, testsFailed: 0, testsSkipped: 0),
        artifacts: JobArtifacts(xcresult: nil, combinedLog: nil, buildLog: nil, testLog: nil, derivedData: nil, diagnostics: nil, junit: nil),
        summaryLine: "Tests succeeded",
        metadata: [:]
    )
}
