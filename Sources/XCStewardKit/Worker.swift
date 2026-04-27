import Foundation

final class Worker {
    private let environment: AppEnvironment
    private let store: StateStore
    private let profileLoader: ProfileLoader
    private let executor: JobExecutor
    private let workerID: String

    init(environment: AppEnvironment, store: StateStore) {
        self.environment = environment
        self.store = store
        self.profileLoader = ProfileLoader(environment: environment)
        self.executor = JobExecutor(environment: environment)
        self.workerID = environment.uuidProvider.makeUUID()
    }

    func run() throws {
        _ = try store.recoverStaleLeaseIfNeeded()
        guard try store.acquireLease(workerID: workerID, pid: getpid()) else {
            return
        }
        defer { try? store.releaseLease() }
        while let job = try store.nextQueuedJob() {
            try store.updateLeaseHeartbeat(jobID: job.id)
            if let current = try store.fetchJob(id: job.id), current.cancelRequested {
                try finishCanceled(job: current)
                continue
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
                try finishFailed(job: job, error: error)
            }
        }
    }

    private func finishCanceled(job: JobRecord) throws {
        let finished = environment.clock.now().timeIntervalSince1970
        let summary = JobSummary(
            jobID: job.id,
            project: job.project,
            state: .canceled,
            resultClass: .canceled,
            exitCode: nil,
            submittedAt: job.createdAt,
            startedAt: job.startedAt,
            finishedAt: finished,
            durationSeconds: job.startedAt.map { finished - $0 },
            testPlan: job.request.testPlan,
            onlyTesting: job.request.onlyTesting,
            simulatorID: job.simulatorID,
            counts: nil,
            artifacts: JobArtifacts(xcresult: nil, combinedLog: nil, buildLog: nil, testLog: nil, derivedData: nil, diagnostics: nil),
            summaryLine: "Canceled",
            metadata: job.request.metadata
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

    private func finishFailed(job: JobRecord, error: Error) throws {
        let finished = environment.clock.now().timeIntervalSince1970
        let startedAt = job.startedAt ?? finished
        let root = URL(fileURLWithPath: job.jobDirectory)
        let summary = JobSummary(
            jobID: job.id,
            project: job.project,
            state: .failed,
            resultClass: .internalError,
            exitCode: nil,
            submittedAt: job.createdAt,
            startedAt: startedAt,
            finishedAt: finished,
            durationSeconds: finished - startedAt,
            testPlan: job.request.testPlan,
            onlyTesting: job.request.onlyTesting,
            simulatorID: job.simulatorID,
            counts: nil,
            artifacts: JobArtifacts(
                xcresult: root.appendingPathComponent("artifacts/result.xcresult").path,
                combinedLog: root.appendingPathComponent("logs/combined.log").path,
                buildLog: root.appendingPathComponent("logs/build.log").path,
                testLog: root.appendingPathComponent("logs/test.log").path,
                derivedData: root.appendingPathComponent("derived-data").path,
                diagnostics: nil
            ),
            summaryLine: String(describing: error),
            metadata: job.request.metadata
        )
        try store.updateJob(
            id: job.id,
            patch: JobStatePatch(
                state: .failed,
                resultClass: .internalError,
                summary: summary,
                startedAt: startedAt,
                finishedAt: finished,
                simulatorID: job.simulatorID
            )
        )
    }
}
