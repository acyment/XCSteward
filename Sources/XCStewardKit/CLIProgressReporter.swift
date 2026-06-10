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
    var phase: String?
    var phaseElapsedSeconds: Double?
    var checkID: String?
    var status: String?
    var schemaVersion: Int = xcstewardSchemaVersion

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
        case phase
        case phaseElapsedSeconds = "phase_elapsed_seconds"
        case checkID = "check_id"
        case status
        case schemaVersion = "schema_version"
    }
}

private struct CLICommandProgress {
    var phase: String?
    var phaseElapsedSeconds: Double?
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
        let commandProgress = job.map { loadCommandProgress(for: $0, now: now) } ?? CLICommandProgress(phase: nil, phaseElapsedSeconds: nil)
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
            phase: commandProgress.phase,
            phaseElapsedSeconds: commandProgress.phaseElapsedSeconds,
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

    private func loadCommandProgress(for job: JobRecord, now: Date) -> CLICommandProgress {
        let commandEventLog = URL(fileURLWithPath: job.jobDirectory)
            .appendingPathComponent("artifacts/command-events.jsonl")
        guard FileManager.default.fileExists(atPath: commandEventLog.path),
              let data = try? Data(contentsOf: commandEventLog),
              let text = String(data: data, encoding: .utf8) else {
            return CLICommandProgress(phase: nil, phaseElapsedSeconds: nil)
        }

        let decoder = JSONDecoder()
        var activeEvents: [String: RunCommandEvent] = [:]
        var lastEvent: RunCommandEvent?
        for line in text.split(separator: "\n") {
            guard let event = try? decoder.decode(RunCommandEvent.self, from: Data(line.utf8)) else {
                continue
            }
            lastEvent = event
            let key = "\(event.phase ?? "")|\(event.tool)|\(event.commandLine)"
            switch event.event {
            case "launching", "started":
                activeEvents[key] = event
            case "finished", "failed":
                activeEvents.removeValue(forKey: key)
            default:
                break
            }
        }

        if let active = activeEvents.values.sorted(by: { $0.timestamp < $1.timestamp }).last {
            return CLICommandProgress(
                phase: active.phase ?? active.tool,
                phaseElapsedSeconds: max(0, now.timeIntervalSince1970 - active.timestamp)
            )
        }
        return CLICommandProgress(
            phase: lastEvent?.phase ?? lastEvent?.tool,
            phaseElapsedSeconds: nil
        )
    }
}
