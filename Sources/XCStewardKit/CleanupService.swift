// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct CleanupJob: Codable, Sendable {
    var jobID: String
    var state: JobState
    var resultClass: ResultClass?
    var finishedAt: Double?
    var jobDirectory: String
    var deleted: Bool
    var bytes: Int64?
    var reason: String

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case state
        case resultClass = "result_class"
        case finishedAt = "finished_at"
        case jobDirectory = "job_directory"
        case deleted
        case bytes
        case reason
    }
}

struct CleanupReport: Codable, Sendable {
    var dryRun: Bool
    var olderThanSeconds: TimeInterval
    var keepLast: Int
    var maxTotalBytes: Int64?
    var cutoff: Double
    var totalManagedBytes: Int64
    var selectedBytes: Int64
    var candidateCount: Int
    var deletedCount: Int
    var candidates: [CleanupJob]

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case olderThanSeconds = "older_than_seconds"
        case keepLast = "keep_last"
        case maxTotalBytes = "max_total_bytes"
        case cutoff
        case totalManagedBytes = "total_managed_bytes"
        case selectedBytes = "selected_bytes"
        case candidateCount = "candidate_count"
        case deletedCount = "deleted_count"
        case candidates
    }
}

struct CleanupService {
    private var environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func cleanupTerminalJobs(
        store: StateStore,
        olderThanSeconds: TimeInterval,
        keepLast: Int,
        maxTotalBytes: Int64?,
        dryRun: Bool
    ) throws -> CleanupReport {
        let now = environment.clock.now().timeIntervalSince1970
        let cutoff = now - olderThanSeconds
        let activeJobIDs = try activeCleanupProtectedJobIDs(store: store)
        let terminalJobs = try store.listJobs()
            .filter(\.state.isTerminal)
        let keptJobIDs = Set(
            terminalJobs
                .sorted { cleanupSortTimestamp($0) > cleanupSortTimestamp($1) }
                .prefix(keepLast)
                .map(\.id)
        )
        var selectable: [CleanupCandidate] = []
        var totalManagedBytes: Int64 = 0
        for job in terminalJobs.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard cleanupJobDirectoryIsUnderJobsRoot(job.jobDirectory),
                  job.processID.map({ !isPIDAlive($0) }) ?? true else {
                continue
            }
            let directory = URL(fileURLWithPath: job.jobDirectory)
            let bytes = cleanupDirectorySize(directory) ?? 0
            totalManagedBytes += bytes
            guard !keptJobIDs.contains(job.id),
                  !activeJobIDs.contains(job.id) else {
                continue
            }
            selectable.append(CleanupCandidate(
                job: job,
                directory: directory,
                bytes: bytes,
                sortTimestamp: cleanupSortTimestamp(job)
            ))
        }

        var selectedReasons: [String: String] = [:]
        for candidate in selectable where candidate.sortTimestamp <= cutoff {
            selectedReasons[candidate.job.id] = "age"
        }

        var selectedBytes = selectable
            .filter { selectedReasons[$0.job.id] != nil }
            .reduce(Int64(0)) { $0 + $1.bytes }
        if let maxTotalBytes {
            var projectedBytes = totalManagedBytes - selectedBytes
            for candidate in selectable.sorted(by: cleanupCandidateSort) where projectedBytes > maxTotalBytes {
                guard selectedReasons[candidate.job.id] == nil else {
                    continue
                }
                selectedReasons[candidate.job.id] = "size_budget"
                selectedBytes += candidate.bytes
                projectedBytes -= candidate.bytes
            }
        }

        var candidates: [CleanupJob] = []
        for candidate in selectable.sorted(by: cleanupCandidateSort) {
            guard let reason = selectedReasons[candidate.job.id] else {
                continue
            }
            if !dryRun {
                try environment.fileSystem.removeItem(candidate.directory)
                try store.deleteTerminalJob(id: candidate.job.id)
            }
            candidates.append(CleanupJob(
                jobID: candidate.job.id,
                state: candidate.job.state,
                resultClass: candidate.job.resultClass,
                finishedAt: candidate.job.finishedAt,
                jobDirectory: candidate.job.jobDirectory,
                deleted: !dryRun,
                bytes: candidate.bytes,
                reason: reason
            ))
        }
        return CleanupReport(
            dryRun: dryRun,
            olderThanSeconds: olderThanSeconds,
            keepLast: keepLast,
            maxTotalBytes: maxTotalBytes,
            cutoff: cutoff,
            totalManagedBytes: totalManagedBytes,
            selectedBytes: selectedBytes,
            candidateCount: candidates.count,
            deletedCount: candidates.filter(\.deleted).count,
            candidates: candidates
        )
    }

    private func activeCleanupProtectedJobIDs(store: StateStore) throws -> Set<String> {
        var ids = Set<String>()
        if let workerJobID = try store.currentLease()?.jobID {
            ids.insert(workerJobID)
        }
        for lease in try store.listSimulatorLeases() {
            ids.insert(lease.jobID)
        }
        return ids
    }

    private func cleanupSortTimestamp(_ job: JobRecord) -> Double {
        job.finishedAt ?? job.startedAt ?? job.createdAt
    }

    private func cleanupCandidateSort(_ lhs: CleanupCandidate, _ rhs: CleanupCandidate) -> Bool {
        if lhs.sortTimestamp == rhs.sortTimestamp {
            return lhs.job.id < rhs.job.id
        }
        return lhs.sortTimestamp < rhs.sortTimestamp
    }

    private func cleanupJobDirectoryIsUnderJobsRoot(_ path: String) -> Bool {
        let root = environment.paths.jobsRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private func cleanupDirectorySize(_ url: URL) -> Int64? {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey],
            options: []
        ) else {
            return nil
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
            ),
                  values.isRegularFile == true else {
                continue
            }
            let allocatedSize = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            total += Int64(allocatedSize)
        }
        return total
    }
}

private struct CleanupCandidate {
    var job: JobRecord
    var directory: URL
    var bytes: Int64
    var sortTimestamp: Double
}
