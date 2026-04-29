import Foundation

struct JobSummaryFactory {
    private let resultPolicy = ResultClassPolicy()

    func queuedCanceledSummary(job: JobRecord, finishedAt: Double) -> JobSummary {
        canceledSummary(
            job: job,
            finishedAt: finishedAt,
            startedAt: nil,
            durationSeconds: 0
        )
    }

    func canceledSummary(
        job: JobRecord,
        finishedAt: Double,
        startedAt: Double?,
        durationSeconds: Double?
    ) -> JobSummary {
        JobSummary(
            jobID: job.id,
            project: job.project,
            state: .canceled,
            resultClass: .canceled,
            exitCode: nil,
            submittedAt: job.createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationSeconds: durationSeconds,
            testPlan: job.request.testPlan,
            onlyTesting: job.request.onlyTesting,
            simulatorID: job.simulatorID,
            counts: nil,
            artifacts: emptyArtifacts(),
            summaryLine: resultPolicy.summaryLine(for: .canceled),
            metadata: job.request.metadata
        )
    }

    func internalFailureSummary(job: JobRecord, error: Error, finishedAt: Double) -> JobSummary {
        let startedAt = job.startedAt ?? finishedAt
        return JobSummary(
            jobID: job.id,
            project: job.project,
            state: .failed,
            resultClass: .internalError,
            exitCode: nil,
            submittedAt: job.createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationSeconds: finishedAt - startedAt,
            testPlan: job.request.testPlan,
            onlyTesting: job.request.onlyTesting,
            simulatorID: job.simulatorID,
            counts: nil,
            artifacts: defaultArtifacts(jobDirectory: job.jobDirectory),
            summaryLine: String(describing: error),
            metadata: job.request.metadata
        )
    }

    func fallbackSummary(job: JobRecord) -> JobSummary {
        JobSummary(
            jobID: job.id,
            project: job.project,
            state: job.state,
            resultClass: job.resultClass,
            exitCode: nil,
            submittedAt: job.createdAt,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            durationSeconds: nil,
            testPlan: job.request.testPlan,
            onlyTesting: job.request.onlyTesting,
            simulatorID: job.simulatorID,
            counts: nil,
            artifacts: defaultArtifacts(jobDirectory: job.jobDirectory),
            summaryLine: job.state.rawValue.capitalized,
            metadata: job.request.metadata
        )
    }

    func emptyArtifacts() -> JobArtifacts {
        JobArtifacts(
            xcresult: nil,
            combinedLog: nil,
            buildLog: nil,
            testLog: nil,
            derivedData: nil,
            diagnostics: nil,
            junit: nil
        )
    }

    func defaultArtifacts(jobDirectory: String) -> JobArtifacts {
        let root = URL(fileURLWithPath: jobDirectory)
        return JobArtifacts(
            xcresult: root.appendingPathComponent("artifacts/result.xcresult").path,
            combinedLog: root.appendingPathComponent("logs/combined.log").path,
            buildLog: root.appendingPathComponent("logs/build.log").path,
            testLog: root.appendingPathComponent("logs/test.log").path,
            derivedData: root.appendingPathComponent("derived-data").path,
            diagnostics: nil,
            junit: nil
        )
    }
}
