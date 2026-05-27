// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import Dispatch

final class Worker: @unchecked Sendable {
    private let environment: AppEnvironment
    private let store: StateStore
    private let profileLoader: ProfileLoader
    private let executor: JobExecutor
    private let hostCapacity: HostCapacityController
    private let workerID: String
    private let maxConcurrentJobs: Int
    private let capacityRetryInterval: TimeInterval = 0.25

    init(environment: AppEnvironment, store: StateStore) {
        self.environment = environment
        self.store = store
        self.profileLoader = ProfileLoader(environment: environment)
        self.executor = JobExecutor(environment: environment)
        self.hostCapacity = HostCapacityController(environment: environment, store: store)
        self.workerID = environment.uuidProvider.makeUUID()
        self.maxConcurrentJobs = Self.maxConcurrentJobs(from: environment.processInfo.environment)
    }

    func run() throws {
        _ = try store.recoverStaleLeaseIfNeeded()
        _ = try store.recoverUnownedRunningJobs()
        _ = try store.recoverStaleSimulatorLeases()
        guard try store.acquireLease(workerID: workerID, pid: getpid()) else {
            return
        }
        defer { try? store.releaseLease() }
        if maxConcurrentJobs <= 1 {
            try runSerial()
        } else {
            try runConcurrent()
        }
    }

    private func runSerial() throws {
        while true {
            guard try hostCapacity.effectiveMaxConcurrentJobs(configuredMax: maxConcurrentJobs) > 0 else {
                guard try store.hasQueuedJobs() else {
                    return
                }
                try store.updateLeaseHeartbeat(jobID: nil)
                Thread.sleep(forTimeInterval: capacityRetryInterval)
                continue
            }
            guard let job = try store.claimNextQueuedJob() else {
                return
            }
            try process(job: job, store: store, profileLoader: profileLoader, executor: executor)
        }
    }

    private func runConcurrent() throws {
        let queue = DispatchQueue(label: "XCSteward.Worker.jobs", attributes: .concurrent)
        let group = DispatchGroup()
        let jobState = ConcurrentJobState()

        func dispatch(_ job: JobRecord) {
            jobState.increment()
            group.enter()
            queue.async {
                defer {
                    jobState.decrement()
                    group.leave()
                }
                do {
                    let jobStore = try StateStore(environment: self.environment)
                    let jobProfileLoader = ProfileLoader(environment: self.environment)
                    let jobExecutor = JobExecutor(environment: self.environment)
                    try self.process(job: job, store: jobStore, profileLoader: jobProfileLoader, executor: jobExecutor)
                } catch {
                    jobState.record(error: error)
                }
            }
        }

        while true {
            let effectiveMaxJobs = try hostCapacity.effectiveMaxConcurrentJobs(
                configuredMax: maxConcurrentJobs,
                activeJobCount: jobState.activeCount
            )
            while jobState.activeCount < effectiveMaxJobs {
                guard let job = try store.claimNextQueuedJob() else {
                    break
                }
                dispatch(job)
            }
            let hasQueuedJobs = try store.hasQueuedJobs()
            if jobState.activeCount == 0, !hasQueuedJobs {
                break
            }
            try store.updateLeaseHeartbeat(jobID: nil)
            Thread.sleep(forTimeInterval: jobState.activeCount == 0 ? capacityRetryInterval : 0.1)
        }
        group.wait()
        if let firstError = jobState.firstError {
            throw firstError
        }
    }

    private func process(job: JobRecord, store: StateStore, profileLoader: ProfileLoader, executor: JobExecutor) throws {
        try store.updateLeaseHeartbeat(jobID: job.id)
        if let current = try store.fetchJob(id: job.id), current.cancelRequested {
            try finishCanceled(job: current, store: store)
            return
        }
        do {
            let profile = try profileLoader.loadProfile(named: job.project)
            let summary = try executor.execute(job: job, profile: profile, store: store)
            try store.updateJob(
                id: job.id,
                patch: JobStatePatch(
                    state: summary.state,
                    resultClass: summary.resultClass,
                    summary: summary,
                    startedAt: summary.startedAt,
                    finishedAt: summary.finishedAt,
                    simulatorID: summary.simulatorID
                )
            )
        } catch {
            try finishFailed(job: job, error: error, store: store)
        }
    }

    private func finishCanceled(job: JobRecord, store: StateStore) throws {
        let finished = environment.clock.now().timeIntervalSince1970
        let summary = JobSummaryFactory().canceledSummary(
            job: job,
            finishedAt: finished,
            startedAt: job.startedAt,
            durationSeconds: job.startedAt.map { finished - $0 }
        )
        try store.updateJob(
            id: job.id,
            patch: JobStatePatch(
                state: .canceled,
                resultClass: .canceled,
                summary: summary,
                finishedAt: finished
            )
        )
    }

    private func finishFailed(job: JobRecord, error: Error, store: StateStore) throws {
        let finished = environment.clock.now().timeIntervalSince1970
        let resultClass = preExecutionResultClass(for: error)
        let summary = JobSummaryFactory().preExecutionFailureSummary(
            job: job,
            error: error,
            resultClass: resultClass,
            finishedAt: finished
        )
        try? persistPreExecutionFailureEvidence(summary: summary, job: job)
        try store.updateJob(
            id: job.id,
            patch: JobStatePatch(
                state: .failed,
                resultClass: resultClass,
                summary: summary,
                startedAt: summary.startedAt,
                finishedAt: finished,
                simulatorID: job.simulatorID
            )
        )
    }

    private func preExecutionResultClass(for error: Error) -> ResultClass {
        switch error {
        case XCStewardError.invalidConfiguration,
             XCStewardError.notFound:
            return .runnerBootstrapFailure
        default:
            return .internalError
        }
    }

    private func persistPreExecutionFailureEvidence(summary: JobSummary, job: JobRecord) throws {
        let paths = ExecutionPaths(job: job)
        try paths.createDirectories(using: environment.fileSystem)
        try environment.fileSystem.writeData(try jsonData(summary), to: paths.summary)
        try environment.fileSystem.writeData(
            try jsonData(PreExecutionFailureRunMetadata(summary: summary)),
            to: paths.runMetadata
        )
        try environment.fileSystem.appendData(Data("\(summary.summaryLine)\n".utf8), to: paths.combinedLog)
    }

    private static func maxConcurrentJobs(from environment: [String: String]) -> Int {
        guard let raw = environment["XCSTEWARD_MAX_CONCURRENT_JOBS"],
              let value = Int(raw),
              value > 0 else {
            return 1
        }
        return value
    }
}

struct PreExecutionFailureRunMetadata: Encodable {
    var jobID: String
    var project: String
    var state: JobState
    var resultClass: ResultClass?
    var submittedAt: Double
    var startedAt: Double?
    var finishedAt: Double?
    var durationSeconds: Double?
    var simulatorID: String?
    var exitCode: Int32?
    var error: String
    var artifacts: JobArtifacts
    var commands: [String]

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case project
        case state
        case resultClass = "result_class"
        case submittedAt = "submitted_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case durationSeconds = "duration_seconds"
        case simulatorID = "simulator_id"
        case exitCode = "exit_code"
        case error
        case artifacts
        case commands
    }

    init(summary: JobSummary) {
        self.jobID = summary.jobID
        self.project = summary.project
        self.state = summary.state
        self.resultClass = summary.resultClass
        self.submittedAt = summary.submittedAt
        self.startedAt = summary.startedAt
        self.finishedAt = summary.finishedAt
        self.durationSeconds = summary.durationSeconds
        self.simulatorID = summary.simulatorID
        self.exitCode = summary.exitCode
        self.error = summary.summaryLine
        self.artifacts = summary.artifacts
        self.commands = []
    }
}

private final class ConcurrentJobState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeJobs = 0
    private var storedError: Error?

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeJobs
    }

    var firstError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func increment() {
        lock.lock()
        activeJobs += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        activeJobs -= 1
        lock.unlock()
    }

    func record(error: Error) {
        lock.lock()
        if storedError == nil {
            storedError = error
        }
        lock.unlock()
    }
}
