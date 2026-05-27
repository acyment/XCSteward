// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct CLIProgressEvent: Encodable {
    var event: String
    var timestamp: Double
    var elapsedSeconds: Double
    var jobID: String?
    var project: String?
    var state: String?
    var resultClass: String?
    var summaryLine: String?
    var processID: Int32?
    var simulatorID: String?
    var checkID: String?
    var status: String?

    enum CodingKeys: String, CodingKey {
        case event
        case timestamp
        case elapsedSeconds = "elapsed_seconds"
        case jobID = "job_id"
        case project
        case state
        case resultClass = "result_class"
        case summaryLine = "summary_line"
        case processID = "process_id"
        case simulatorID = "simulator_id"
        case checkID = "check_id"
        case status
    }
}

final class CLIProgressReporter {
    private let enabled: Bool
    private let startedAt: Date
    private let clock: Clock
    private let output: FileHandle
    private let encoder: JSONEncoder

    init(enabled: Bool, clock: Clock, output: FileHandle = .standardError) {
        self.enabled = enabled
        self.startedAt = clock.now()
        self.clock = clock
        self.output = output
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    func emit(
        _ event: String,
        job: JobRecord? = nil,
        checkID: String? = nil,
        status: String? = nil
    ) {
        guard enabled else {
            return
        }
        let now = clock.now()
        let summary = job.flatMap { try? loadPersistedSummary(for: $0) } ?? job?.summary
        let progressEvent = CLIProgressEvent(
            event: event,
            timestamp: now.timeIntervalSince1970,
            elapsedSeconds: now.timeIntervalSince(startedAt),
            jobID: job?.id,
            project: job?.project,
            state: job?.state.rawValue,
            resultClass: (summary?.resultClass ?? job?.resultClass)?.rawValue,
            summaryLine: summary?.summaryLine ?? job?.summary?.summaryLine,
            processID: job?.processID,
            simulatorID: job?.simulatorID,
            checkID: checkID,
            status: status
        )
        guard let data = try? encoder.encode(progressEvent) else {
            return
        }
        output.write(data)
        output.write(Data("\n".utf8))
    }

    private func loadPersistedSummary(for job: JobRecord) throws -> JobSummary? {
        let summaryURL = URL(fileURLWithPath: job.jobDirectory).appendingPathComponent("artifacts/summary.json")
        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            return nil
        }
        return try decodeJSON(JobSummary.self, from: Data(contentsOf: summaryURL))
    }
}
