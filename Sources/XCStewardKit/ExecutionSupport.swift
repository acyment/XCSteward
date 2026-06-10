// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct ToolExecutionContext {
    let profile: ProjectProfile
    let jobID: String
    let store: StateStore
    var envOverrides: [String: String] = [:]
    var commandLog: URL? = nil
    var commandEventLog: URL? = nil
}

struct TestOutcome: Sendable {
    var resultClass: ResultClass
    var exitCode: Int32?
    var summaryLine: String? = nil
    var diagnosticExcerpt: JobDiagnosticExcerpt? = nil
}

struct RunCommandRecord: Codable, Sendable {
    var tool: String
    var arguments: [String]
    var commandLine: String
    var workingDirectory: String?
    var timeoutSeconds: Double
    var phase: String?
    var exitCode: Int32?
    var timedOut: Bool
    var error: String?

    enum CodingKeys: String, CodingKey {
        case tool
        case arguments
        case commandLine = "command_line"
        case workingDirectory = "working_directory"
        case timeoutSeconds = "timeout_seconds"
        case phase
        case exitCode = "exit_code"
        case timedOut = "timed_out"
        case error
    }
}

struct RunCommandEvent: Codable, Sendable {
    var event: String
    var timestamp: Double
    var tool: String
    var arguments: [String]
    var commandLine: String
    var workingDirectory: String?
    var timeoutSeconds: Double
    var phase: String?
    var pid: Int32?
    var exitCode: Int32?
    var timedOut: Bool?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case event
        case timestamp
        case tool
        case arguments
        case commandLine = "command_line"
        case workingDirectory = "working_directory"
        case timeoutSeconds = "timeout_seconds"
        case phase
        case pid
        case exitCode = "exit_code"
        case timedOut = "timed_out"
        case error
    }
}

struct AttemptArtifact: Codable, Sendable {
    var attempt: Int
    var phase: String
    var resultClass: ResultClass
    var exitCode: Int32?
    var timedOut: Bool
    var retryReason: String?
    var resultBundle: String?
    var resultStream: String?
    var metadata: String

    enum CodingKeys: String, CodingKey {
        case attempt
        case phase
        case resultClass = "result_class"
        case exitCode = "exit_code"
        case timedOut = "timed_out"
        case retryReason = "retry_reason"
        case resultBundle = "result_bundle"
        case resultStream = "result_stream"
        case metadata
    }
}

struct AttemptArtifactPaths: Sendable {
    var root: URL
    var resultBundle: URL
    var resultStream: URL
    var metadata: URL
}

struct RetryAttemptEvidence: Sendable {
    var retryReason: String
    var artifact: AttemptArtifact
    var simulatorDiagnostic: String?
}

struct XcodebuildTestAttempt: Sendable {
    var arguments: [String]
    var simulatorID: String
    var resultStream: URL
    var logURL: URL
    var combinedLog: URL
    var temporaryDirectory: URL
    var phase: String
    var shardID: String?
    var shardIndex: Int?
    var totalShards: Int?
}

struct ShardReport: Codable, Sendable {
    var shardID: String
    var simulatorID: String
    var onlyTesting: [String]
    var resultBundle: String
    var resultStream: String?
    var log: String
    var resultClass: ResultClass
    var exitCode: Int32?
    var counts: JobCounts?
    var attempts: Int
    var retryReason: String?
    var simulatorDiagnostics: [String]
    var attemptArtifacts: [AttemptArtifact] = []

    enum CodingKeys: String, CodingKey {
        case shardID = "shard_id"
        case simulatorID = "simulator_id"
        case onlyTesting = "only_testing"
        case resultBundle = "result_bundle"
        case resultStream = "result_stream"
        case log
        case resultClass = "result_class"
        case exitCode = "exit_code"
        case counts
        case attempts
        case retryReason = "retry_reason"
        case simulatorDiagnostics = "simulator_diagnostics"
        case attemptArtifacts = "attempt_artifacts"
    }
}

struct ShardPaths: Sendable {
    var id: String
    var root: URL
    var testLog: URL
    var resultBundle: URL
    var resultStream: URL
    var temporaryDirectory: URL

    func simulatorDiagnostics(attempt: Int) -> URL {
        root.appendingPathComponent("simctl-diagnose-attempt-\(attempt).log")
    }

    func attemptPaths(attempt: Int) -> AttemptArtifactPaths {
        let root = self.root.appendingPathComponent("attempts")
            .appendingPathComponent(String(format: "attempt-%03d", attempt))
        return AttemptArtifactPaths(
            root: root,
            resultBundle: root.appendingPathComponent("result.xcresult"),
            resultStream: root.appendingPathComponent("result-stream.json"),
            metadata: root.appendingPathComponent("attempt-metadata.json")
        )
    }
}

enum TestProductReference: Sendable {
    case xctestrun(URL)
    case testProducts(URL)

    var arguments: [String] {
        switch self {
        case let .xctestrun(url):
            return ["-xctestrun", url.path]
        case let .testProducts(url):
            return ["-testProductsPath", url.path]
        }
    }
}

struct ManualRunResult: Sendable {
    var resultClass: ResultClass
    var exitCode: Int32?
    var counts: JobCounts?
    var artifacts: JobArtifacts
    var shardReports: [ShardReport]
    var successSummaryLine: String?
}

struct ExecutionPaths {
    let jobRoot: URL
    let logsRoot: URL
    let artifactsRoot: URL
    let attemptsRoot: URL
    let shardsRoot: URL
    let temporaryRoot: URL
    let derivedData: URL
    let testProducts: URL
    let buildLog: URL
    let testLog: URL
    let combinedLog: URL
    let resultBundle: URL
    let resultStream: URL
    let mergedResultBundle: URL
    let summary: URL
    let testEnumeration: URL
    let shardsManifest: URL
    let combinedSummary: URL
    let simulatorDiagnostics: URL
    let junitReport: URL
    let runMetadata: URL
    let commandLog: URL
    let commandEventLog: URL
    let xcodebuildHelp: URL

    init(job: JobRecord) {
        self.jobRoot = URL(fileURLWithPath: job.jobDirectory)
        self.logsRoot = jobRoot.appendingPathComponent("logs")
        self.artifactsRoot = jobRoot.appendingPathComponent("artifacts")
        self.attemptsRoot = artifactsRoot.appendingPathComponent("attempts")
        self.shardsRoot = artifactsRoot.appendingPathComponent("shards")
        self.temporaryRoot = jobRoot.appendingPathComponent("tmp")
        self.derivedData = jobRoot.appendingPathComponent("derived-data")
        self.testProducts = artifactsRoot.appendingPathComponent("test-products.xctestproducts")
        self.buildLog = logsRoot.appendingPathComponent("build.log")
        self.testLog = logsRoot.appendingPathComponent("test.log")
        self.combinedLog = logsRoot.appendingPathComponent("combined.log")
        self.resultBundle = artifactsRoot.appendingPathComponent("result.xcresult")
        self.resultStream = artifactsRoot.appendingPathComponent("result-stream.json")
        self.mergedResultBundle = artifactsRoot.appendingPathComponent("merged.xcresult")
        self.summary = artifactsRoot.appendingPathComponent("summary.json")
        self.testEnumeration = artifactsRoot.appendingPathComponent("tests.json")
        self.shardsManifest = artifactsRoot.appendingPathComponent("shards.json")
        self.combinedSummary = artifactsRoot.appendingPathComponent("combined-summary.json")
        self.simulatorDiagnostics = artifactsRoot.appendingPathComponent("simctl-diagnose.log")
        self.junitReport = artifactsRoot.appendingPathComponent("junit.xml")
        self.runMetadata = artifactsRoot.appendingPathComponent("run-metadata.json")
        self.commandLog = artifactsRoot.appendingPathComponent("commands.jsonl")
        self.commandEventLog = artifactsRoot.appendingPathComponent("command-events.jsonl")
        self.xcodebuildHelp = artifactsRoot.appendingPathComponent("xcodebuild-help.txt")
    }

    func createDirectories(using fileSystem: FileSystem) throws {
        try fileSystem.createDirectory(logsRoot)
        try fileSystem.createDirectory(artifactsRoot)
        try fileSystem.createDirectory(temporaryRoot)
        try fileSystem.createDirectory(derivedData)
    }

    func shardPaths(index: Int) -> ShardPaths {
        let id = String(format: "shard-%03d", index)
        let root = shardsRoot.appendingPathComponent(id)
        return ShardPaths(
            id: id,
            root: root,
            testLog: root.appendingPathComponent("test.log"),
            resultBundle: root.appendingPathComponent("result.xcresult"),
            resultStream: root.appendingPathComponent("result-stream.json"),
            temporaryDirectory: root.appendingPathComponent("tmp")
        )
    }

    func testAttemptPaths(attempt: Int) -> AttemptArtifactPaths {
        let root = attemptsRoot.appendingPathComponent(String(format: "test-attempt-%03d", attempt))
        return AttemptArtifactPaths(
            root: root,
            resultBundle: root.appendingPathComponent("result.xcresult"),
            resultStream: root.appendingPathComponent("result-stream.json"),
            metadata: root.appendingPathComponent("attempt-metadata.json")
        )
    }

    func artifacts(fileSystem: FileSystem) -> JobArtifacts {
        JobArtifacts(
            xcresult: fileSystem.fileExists(resultBundle) ? resultBundle.path : nil,
            combinedLog: combinedLog.path,
            buildLog: buildLog.path,
            testLog: testLog.path,
            derivedData: derivedData.path,
            diagnostics: fileSystem.fileExists(simulatorDiagnostics) ? simulatorDiagnostics.path : nil,
            junit: fileSystem.isRegularFile(junitReport) ? junitReport.path : nil,
            commandEvents: fileSystem.fileExists(commandEventLog) ? commandEventLog.path : nil
        )
    }

    var initialArtifacts: JobArtifacts {
        JobArtifacts(
            xcresult: nil,
            combinedLog: combinedLog.path,
            buildLog: buildLog.path,
            testLog: testLog.path,
            derivedData: derivedData.path,
            diagnostics: nil,
            junit: nil,
            commandEvents: commandEventLog.path
        )
    }

    func manualShardArtifacts(fileSystem: FileSystem) -> JobArtifacts {
        JobArtifacts(
            xcresult: fileSystem.fileExists(mergedResultBundle) ? mergedResultBundle.path : nil,
            combinedLog: combinedLog.path,
            buildLog: buildLog.path,
            testLog: testLog.path,
            derivedData: derivedData.path,
            diagnostics: fileSystem.fileExists(combinedSummary)
                ? combinedSummary.path
                : (fileSystem.fileExists(shardsManifest) ? shardsManifest.path : nil),
            junit: fileSystem.isRegularFile(junitReport) ? junitReport.path : nil,
            commandEvents: fileSystem.fileExists(commandEventLog) ? commandEventLog.path : nil
        )
    }
}

@discardableResult
func preserveAttemptArtifacts(
    fileSystem: FileSystem,
    sourceResultBundle: URL,
    sourceResultStream: URL,
    attemptPaths: AttemptArtifactPaths,
    attempt: Int,
    phase: String,
    resultClass: ResultClass,
    exitCode: Int32?,
    timedOut: Bool,
    retryReason: String?
) throws -> AttemptArtifact {
    try fileSystem.createDirectory(attemptPaths.root)
    let resultBundlePath: String?
    if fileSystem.fileExists(sourceResultBundle) {
        try fileSystem.moveItem(sourceResultBundle, to: attemptPaths.resultBundle)
        resultBundlePath = attemptPaths.resultBundle.path
    } else {
        resultBundlePath = nil
    }

    let resultStreamPath: String?
    if fileSystem.fileExists(sourceResultStream) {
        try fileSystem.moveItem(sourceResultStream, to: attemptPaths.resultStream)
        resultStreamPath = attemptPaths.resultStream.path
    } else {
        resultStreamPath = nil
    }

    let artifact = AttemptArtifact(
        attempt: attempt,
        phase: phase,
        resultClass: resultClass,
        exitCode: exitCode,
        timedOut: timedOut,
        retryReason: retryReason,
        resultBundle: resultBundlePath,
        resultStream: resultStreamPath,
        metadata: attemptPaths.metadata.path
    )
    try fileSystem.writeData(try jsonData(artifact), to: attemptPaths.metadata)
    return artifact
}

@discardableResult
func recordRetryAttemptEvidence(
    fileSystem: FileSystem,
    sourceResultBundle: URL,
    sourceResultStream: URL,
    attemptPaths: AttemptArtifactPaths,
    attempt: Int,
    phase: String,
    outcome: TestOutcome,
    run: ToolResult,
    captureSimulatorDiagnostic: () -> String?
) throws -> RetryAttemptEvidence {
    let retryReason = outcome.resultClass.rawValue
    let artifact = try preserveAttemptArtifacts(
        fileSystem: fileSystem,
        sourceResultBundle: sourceResultBundle,
        sourceResultStream: sourceResultStream,
        attemptPaths: attemptPaths,
        attempt: attempt,
        phase: phase,
        resultClass: outcome.resultClass,
        exitCode: run.exitCode,
        timedOut: run.timedOut,
        retryReason: retryReason
    )
    return RetryAttemptEvidence(
        retryReason: retryReason,
        artifact: artifact,
        simulatorDiagnostic: captureSimulatorDiagnostic()
    )
}
