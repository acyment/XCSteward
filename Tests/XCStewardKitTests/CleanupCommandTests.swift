// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

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
        let oldDirectory = try seedCleanupJob(store: store, stateRoot: stateRoot, id: "old-job", createdAt: 1, finishedAt: 2, artifactBytes: 3 * 1024 * 1024)
        let middleDirectory = try seedCleanupJob(store: store, stateRoot: stateRoot, id: "middle-job", createdAt: 3, finishedAt: 4, artifactBytes: 2 * 1024 * 1024)
        let newDirectory = try seedCleanupJob(store: store, stateRoot: stateRoot, id: "new-job", createdAt: 5, finishedAt: 6, artifactBytes: 1024 * 1024)
        let oldBytes = try allocatedRegularFileBytes(in: oldDirectory)
        let middleBytes = try allocatedRegularFileBytes(in: middleDirectory)
        let newBytes = try allocatedRegularFileBytes(in: newDirectory)
        let totalBytes = oldBytes + middleBytes + newBytes
        let maxTotalBytes = middleBytes + newBytes

        let result = try runCLI(arguments: [
            "cleanup",
            "--state-root", stateRoot.path,
            "--older-than", "999999d",
            "--keep-last", "1",
            "--max-total-size", "\(maxTotalBytes)b",
            "--json",
        ])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let report = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(report["dry_run"] as? Bool, true)
        XCTAssertEqual(report["max_total_bytes"] as? Int, maxTotalBytes)
        XCTAssertEqual(report["total_managed_bytes"] as? Int, totalBytes)
        XCTAssertEqual(report["selected_bytes"] as? Int, oldBytes)
        XCTAssertEqual(report["candidate_count"] as? Int, 1)
        let candidates = try XCTUnwrap(report["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.first?["job_id"] as? String, "old-job")
        XCTAssertEqual(candidates.first?["reason"] as? String, "size_budget")
        XCTAssertNotNil(try store.fetchJob(id: "old-job"))
        XCTAssertNotNil(try store.fetchJob(id: "middle-job"))
        XCTAssertNotNil(try store.fetchJob(id: "new-job"))
    }

    func testCleanupReportsAllocatedBytesForSparseArtifacts() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        let jobDirectory = try seedCleanupJob(
            store: store,
            stateRoot: stateRoot,
            id: "sparse-job",
            createdAt: 1,
            finishedAt: 2,
            artifactBytes: 0
        )
        let sparseArtifact = jobDirectory.appendingPathComponent("artifacts/sparse.bin")
        FileManager.default.createFile(atPath: sparseArtifact.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparseArtifact)
        try handle.truncate(atOffset: 32 * 1024 * 1024)
        try handle.close()
        let allocatedBytes = try allocatedRegularFileBytes(in: jobDirectory)

        let result = try runCLI(arguments: [
            "cleanup",
            "--state-root", stateRoot.path,
            "--older-than", "0s",
            "--keep-last", "0",
            "--json",
        ])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let report = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(report["total_managed_bytes"] as? Int, allocatedBytes)
        let candidates = try XCTUnwrap(report["candidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.first?["bytes"] as? Int, allocatedBytes)
        XCTAssertLessThan(allocatedBytes, 32 * 1024 * 1024)
    }

    func testCleanupCachesDryRunReportsCachesWithoutSelectingJobs() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        try seedCleanupJob(store: store, stateRoot: stateRoot, id: "old-job", createdAt: 1, finishedAt: 2)
        try seedCleanupCaches(stateRoot: stateRoot)

        let result = try runCLI(arguments: [
            "cleanup",
            "--state-root", stateRoot.path,
            "--caches",
            "--json",
        ])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let report = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(report["dry_run"] as? Bool, true)
        XCTAssertEqual(report["candidate_count"] as? Int, 0)
        XCTAssertEqual(report["deleted_count"] as? Int, 0)
        XCTAssertEqual(report["cache_candidate_count"] as? Int, 3)
        XCTAssertEqual(report["cache_deleted_count"] as? Int, 0)
        XCTAssertGreaterThan(report["cache_selected_bytes"] as? Int ?? 0, 0)
        let cacheCandidates = try XCTUnwrap(report["cache_candidates"] as? [[String: Any]])
        let candidatePaths = Set(cacheCandidates.compactMap { $0["path"] as? String })
        XCTAssertTrue(candidatePaths.contains(stateRoot.appendingPathComponent("host-health.json").path))
        XCTAssertTrue(candidatePaths.contains(stateRoot.appendingPathComponent("doctor/last-report.json").path))
        XCTAssertTrue(candidatePaths.contains(stateRoot.appendingPathComponent("doctor/xctestrun-integrity").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("jobs/old-job").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("doctor/last-report.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("host-health.json").path))
    }

    func testCleanupCachesApplyDeletesCachesOnly() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        try seedCleanupJob(store: store, stateRoot: stateRoot, id: "old-job", createdAt: 1, finishedAt: 2)
        try seedCleanupCaches(stateRoot: stateRoot)

        let result = try runCLI(arguments: [
            "cleanup",
            "--state-root", stateRoot.path,
            "--caches",
            "--apply",
            "--json",
        ])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let report = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(report["dry_run"] as? Bool, false)
        XCTAssertEqual(report["candidate_count"] as? Int, 0)
        XCTAssertEqual(report["deleted_count"] as? Int, 0)
        XCTAssertEqual(report["cache_candidate_count"] as? Int, 3)
        XCTAssertEqual(report["cache_deleted_count"] as? Int, 3)
        XCTAssertNotNil(try store.fetchJob(id: "old-job"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("jobs/old-job").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("doctor/last-report.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("doctor/xctestrun-integrity").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateRoot.appendingPathComponent("host-health.json").path))
    }

    func testCleanupCachesRejectsJobCleanupFilters() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")

        let result = try runCLI(arguments: [
            "cleanup",
            "--state-root", stateRoot.path,
            "--caches",
            "--older-than", "1d",
            "--json",
        ])

        XCTAssertEqual(result.status, 2)
        XCTAssertEqual(result.stdout, "")
        let envelope = try XCTUnwrap(parseJSON(result.stderr) as? [String: Any])
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertEqual(error["message"] as? String, "cleanup --caches cannot combine with job cleanup filters")
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

    func testCleanupServiceSkipsSymlinkedJobDirectoryResolvingOutsideJobsRoot() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let outsideDirectory = temp.appendingPathComponent("external-target")
        let environment = AppEnvironment(paths: AppPaths(stateRoot: stateRoot))
        let store = try StateStore(environment: environment)
        try FileManager.default.createDirectory(
            at: outsideDirectory.appendingPathComponent("artifacts"),
            withIntermediateDirectories: true
        )
        let outsideArtifact = outsideDirectory.appendingPathComponent("artifacts/result.txt")
        try Data(repeating: UInt8(ascii: "x"), count: 32).write(to: outsideArtifact)
        let symlinkDirectory = stateRoot.appendingPathComponent("jobs/symlink-job")
        try FileManager.default.createSymbolicLink(at: symlinkDirectory, withDestinationURL: outsideDirectory)
        try store.createJob(cleanupJobRecord(
            id: "symlink-job",
            state: .succeeded,
            createdAt: 1,
            finishedAt: 2,
            jobDirectory: symlinkDirectory.path
        ))

        let report = try CleanupService(environment: environment).cleanupTerminalJobs(
            store: store,
            olderThanSeconds: 0,
            keepLast: 0,
            maxTotalBytes: nil,
            dryRun: false
        )

        XCTAssertEqual(report.candidateCount, 0)
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertNotNil(try store.fetchJob(id: "symlink-job"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlinkDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideArtifact.path))
    }
}

@discardableResult
private func seedCleanupJob(
    store: StateStore,
    stateRoot: URL,
    id: String,
    state: JobState = .succeeded,
    createdAt: Double,
    finishedAt: Double?,
    artifactBytes: Int = 8,
    jobDirectory explicitJobDirectory: URL? = nil
) throws -> URL {
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
    try store.createJob(cleanupJobRecord(
        id: id,
        state: state,
        createdAt: createdAt,
        finishedAt: finishedAt,
        jobDirectory: jobDirectory.path,
        request: request
    ))
    return jobDirectory
}

private func seedCleanupCaches(stateRoot: URL) throws {
    try writeText("{}", to: stateRoot.appendingPathComponent("host-health.json"))
    try writeText("{}", to: stateRoot.appendingPathComponent("doctor/last-report.json"))
    try writeText(
        "doctor evidence",
        to: stateRoot.appendingPathComponent("doctor/xctestrun-integrity/demo/evidence.json")
    )
}

private func allocatedRegularFileBytes(in directory: URL) throws -> Int {
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey],
        options: []
    ))
    var total = 0
    for case let fileURL as URL in enumerator {
        let values = try fileURL.resourceValues(
            forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        )
        guard values.isRegularFile == true else {
            continue
        }
        total += values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
    }
    return total
}

private func cleanupJobRecord(
    id: String,
    state: JobState,
    createdAt: Double,
    finishedAt: Double?,
    jobDirectory: String,
    request: JobRequest = JobRequest(
        project: "demo",
        testPlan: nil,
        onlyTesting: [],
        simulatorID: nil,
        metadata: [:],
        wait: false
    )
) -> JobRecord {
    JobRecord(
        id: id,
        project: "demo",
        state: state,
        resultClass: state == .succeeded ? .success : nil,
        request: request,
        summary: nil,
        jobDirectory: jobDirectory,
        createdAt: createdAt,
        startedAt: state == .queued ? nil : createdAt,
        finishedAt: finishedAt,
        processID: nil,
        simulatorID: nil,
        cancelRequested: false
    )
}
