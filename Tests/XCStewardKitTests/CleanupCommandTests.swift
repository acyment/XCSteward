import Darwin
import Foundation
import XCTest
@testable import XCStewardKit

final class CleanupCommandTests: XCTestCase {
    func testCleanupDryRunReportsEligibleTerminalJobsWithoutDeleting() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        try seedCleanupJob(store: store, stateRoot: stateRoot, id: "old-job", createdAt: 1, finishedAt: 2)
        try seedCleanupJob(store: store, stateRoot: stateRoot, id: "new-job", createdAt: 10, finishedAt: 20)
        try seedCleanupJob(store: store, stateRoot: stateRoot, id: "running-job", state: .running, createdAt: 1, finishedAt: nil)

        let result = try runCLI(arguments: [
            "cleanup",
            "--state-root", stateRoot.path,
            "--older-than", "0s",
            "--keep-last", "1",
            "--json",
        ])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let report = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(report["dry_run"] as? Bool, true)
        XCTAssertEqual(report["candidate_count"] as? Int, 1)
        XCTAssertEqual(report["deleted_count"] as? Int, 0)
        let candidates = try XCTUnwrap(report["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.first?["job_id"] as? String, "old-job")
        XCTAssertNotNil(try store.fetchJob(id: "old-job"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("jobs/old-job").path))
    }

    func testCleanupApplyDeletesOnlyEligibleTerminalJobs() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        try seedCleanupJob(store: store, stateRoot: stateRoot, id: "delete-job", createdAt: 1, finishedAt: 2)
        try seedCleanupJob(store: store, stateRoot: stateRoot, id: "leased-job", createdAt: 1, finishedAt: 2)
        XCTAssertTrue(try store.acquireSimulatorLease(simulatorID: "SIM-LEASED", jobID: "leased-job", pid: getpid()))

        let result = try runCLI(arguments: [
            "cleanup",
            "--state-root", stateRoot.path,
            "--older-than", "0s",
            "--keep-last", "0",
            "--apply",
            "--json",
        ])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let report = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(report["dry_run"] as? Bool, false)
        XCTAssertEqual(report["candidate_count"] as? Int, 1)
        XCTAssertEqual(report["deleted_count"] as? Int, 1)
        XCTAssertNil(try store.fetchJob(id: "delete-job"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("jobs/delete-job").path))
        XCTAssertNotNil(try store.fetchJob(id: "leased-job"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("jobs/leased-job").path))
    }

    func testCleanupSizeBudgetSelectsOldestEligibleJobs() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        try seedCleanupJob(store: store, stateRoot: stateRoot, id: "old-job", createdAt: 1, finishedAt: 2, artifactBytes: 60)
        try seedCleanupJob(store: store, stateRoot: stateRoot, id: "middle-job", createdAt: 3, finishedAt: 4, artifactBytes: 50)
        try seedCleanupJob(store: store, stateRoot: stateRoot, id: "new-job", createdAt: 5, finishedAt: 6, artifactBytes: 40)

        let result = try runCLI(arguments: [
            "cleanup",
            "--state-root", stateRoot.path,
            "--older-than", "999999d",
            "--keep-last", "1",
            "--max-total-size", "90b",
            "--json",
        ])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let report = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(report["dry_run"] as? Bool, true)
        XCTAssertEqual(report["max_total_bytes"] as? Int, 90)
        XCTAssertEqual(report["total_managed_bytes"] as? Int, 150)
        XCTAssertEqual(report["selected_bytes"] as? Int, 60)
        XCTAssertEqual(report["candidate_count"] as? Int, 1)
        let candidates = try XCTUnwrap(report["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.first?["job_id"] as? String, "old-job")
        XCTAssertEqual(candidates.first?["reason"] as? String, "size_budget")
        XCTAssertNotNil(try store.fetchJob(id: "old-job"))
        XCTAssertNotNil(try store.fetchJob(id: "middle-job"))
        XCTAssertNotNil(try store.fetchJob(id: "new-job"))
    }

    func testCleanupServiceIgnoresTerminalJobOutsideJobsRoot() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let outsideDirectory = temp.appendingPathComponent("external-job")
        let environment = AppEnvironment(paths: AppPaths(stateRoot: stateRoot))
        let store = try StateStore(environment: environment)
        try seedCleanupJob(
            store: store,
            stateRoot: stateRoot,
            id: "external-job",
            createdAt: 1,
            finishedAt: 2,
            jobDirectory: outsideDirectory
        )

        let report = try CleanupService(environment: environment).cleanupTerminalJobs(
            store: store,
            olderThanSeconds: 0,
            keepLast: 0,
            maxTotalBytes: nil,
            dryRun: false
        )

        XCTAssertEqual(report.candidateCount, 0)
        XCTAssertNil(report.candidates.first)
        XCTAssertNotNil(try store.fetchJob(id: "external-job"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideDirectory.path))
    }
}

private func seedCleanupJob(
    store: StateStore,
    stateRoot: URL,
    id: String,
    state: JobState = .succeeded,
    createdAt: Double,
    finishedAt: Double?,
    artifactBytes: Int = 8,
    jobDirectory explicitJobDirectory: URL? = nil
) throws {
    let jobDirectory = explicitJobDirectory ?? stateRoot.appendingPathComponent("jobs/\(id)")
    try FileManager.default.createDirectory(at: jobDirectory.appendingPathComponent("artifacts"), withIntermediateDirectories: true)
    try Data(repeating: UInt8(ascii: "x"), count: artifactBytes)
        .write(to: jobDirectory.appendingPathComponent("artifacts/result.txt"))
    let request = JobRequest(
        project: "demo",
        testPlan: nil,
        onlyTesting: [],
        simulatorID: nil,
        metadata: [:],
        wait: false
    )
    try store.createJob(JobRecord(
        id: id,
        project: "demo",
        state: state,
        resultClass: state == .succeeded ? .success : nil,
        request: request,
        summary: nil,
        jobDirectory: jobDirectory.path,
        createdAt: createdAt,
        startedAt: state == .queued ? nil : createdAt,
        finishedAt: finishedAt,
        processID: nil,
        simulatorID: nil,
        cancelRequested: false
    ))
}
