import Foundation

struct XCResultSummary: Decodable, Sendable {
    var testsCount: Int
    var testsFailedCount: Int
    var testsSkippedCount: Int

    enum CodingKeys: String, CodingKey {
        case testsCount
        case testsFailedCount
        case testsSkippedCount
        case totalTestCount
        case failedTests
        case skippedTests
    }

    init(testsCount: Int, testsFailedCount: Int, testsSkippedCount: Int) {
        self.testsCount = testsCount
        self.testsFailedCount = testsFailedCount
        self.testsSkippedCount = testsSkippedCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let testsCount = try container.decodeIfPresent(Int.self, forKey: .testsCount) {
            self.testsCount = testsCount
            self.testsFailedCount = try container.decodeIfPresent(Int.self, forKey: .testsFailedCount) ?? 0
            self.testsSkippedCount = try container.decodeIfPresent(Int.self, forKey: .testsSkippedCount) ?? 0
            return
        }

        if let totalTestCount = try container.decodeIfPresent(Int.self, forKey: .totalTestCount) {
            self.testsCount = totalTestCount
            self.testsFailedCount = try container.decodeIfPresent(Int.self, forKey: .failedTests) ?? 0
            self.testsSkippedCount = try container.decodeIfPresent(Int.self, forKey: .skippedTests) ?? 0
            return
        }

        throw DecodingError.keyNotFound(
            CodingKeys.testsCount,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected either legacy testsCount or modern totalTestCount in xcresulttool summary"
            )
        )
    }
}

struct JUnitTestCase: Sendable {
    var className: String
    var name: String
    var timeSeconds: Double
    var failureMessage: String?
    var errorMessage: String?
    var skipped: Bool
}

struct ProbeWarning: Codable, Sendable {
    var source: String
    var command: String
    var message: String
    var exitCode: Int32?
    var timedOut: Bool?
    var outputExcerpt: String?

    enum CodingKeys: String, CodingKey {
        case source
        case command
        case message
        case exitCode = "exit_code"
        case timedOut = "timed_out"
        case outputExcerpt = "output_excerpt"
    }
}

final class ProbeWarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ProbeWarning] = []

    func record(_ warning: ProbeWarning) {
        lock.lock()
        recorded.append(warning)
        lock.unlock()
    }

    func drain() -> [ProbeWarning] {
        lock.lock()
        defer { lock.unlock() }
        let warnings = recorded
        recorded = []
        return warnings
    }
}

private struct ManualShardRunDiagnostics: Codable, Sendable {
    var jobID: String
    var project: String
    var mode: ParallelMode
    var resultClass: ResultClass
    var shardCount: Int
    var retryCount: Int
    var failedShardCount: Int
    var counts: JobCounts?
    var mergedResultBundle: String?
    var shardsManifest: String
    var simulatorDiagnostics: [String]
    var shards: [ShardReport]

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case project
        case mode
        case resultClass = "result_class"
        case shardCount = "shard_count"
        case retryCount = "retry_count"
        case failedShardCount = "failed_shard_count"
        case counts
        case mergedResultBundle = "merged_result_bundle"
        case shardsManifest = "shards_manifest"
        case simulatorDiagnostics = "simulator_diagnostics"
        case shards
    }
}

private struct RunMetadata: Codable, Sendable {
    var jobID: String
    var project: String
    var state: JobState
    var resultClass: ResultClass?
    var simulatorID: String
    var startedAt: Double
    var finishedAt: Double
    var durationSeconds: Double
    var xcodeVersion: String?
    var xcodebuildPath: String?
    var macOSVersion: String
    var exitCode: Int32?
    var timedOut: Bool
    var canceled: Bool
    var request: RunRequestMetadata
    var profile: RunProfileMetadata
    var artifacts: JobArtifacts
    var derivedDataPath: String?
    var resultBundlePath: String?
    var summaryPath: String
    var commandLogPath: String?
    var commandEventLogPath: String?
    var combinedLogPath: String?
    var buildLogPath: String?
    var testLogPath: String?
    var junitPath: String?
    var testProductsPath: String?
    var resultStreamPath: String?
    var xcodebuildHelpPath: String?
    var commands: [RunCommandRecord]
    var attempts: [AttemptArtifact]
    var probeWarnings: [ProbeWarning]

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case project
        case state
        case resultClass = "result_class"
        case simulatorID = "simulator_id"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case durationSeconds = "duration_seconds"
        case xcodeVersion = "xcode_version"
        case xcodebuildPath = "xcodebuild_path"
        case macOSVersion = "macos_version"
        case exitCode = "exit_code"
        case timedOut = "timed_out"
        case canceled
        case request
        case profile
        case artifacts
        case derivedDataPath = "derived_data_path"
        case resultBundlePath = "result_bundle_path"
        case summaryPath = "summary_path"
        case commandLogPath = "command_log_path"
        case commandEventLogPath = "command_event_log_path"
        case combinedLogPath = "combined_log_path"
        case buildLogPath = "build_log_path"
        case testLogPath = "test_log_path"
        case junitPath = "junit_path"
        case testProductsPath = "test_products_path"
        case resultStreamPath = "result_stream_path"
        case xcodebuildHelpPath = "xcodebuild_help_path"
        case commands
        case attempts
        case probeWarnings = "probe_warnings"
    }
}

private struct RunRequestMetadata: Codable, Sendable {
    var testPlan: String?
    var onlyTesting: [String]
    var skipTesting: [String]
    var onlyTestConfigurations: [String]
    var skipTestConfigurations: [String]
    var metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case testPlan = "test_plan"
        case onlyTesting = "only_testing"
        case skipTesting = "skip_testing"
        case onlyTestConfigurations = "only_test_configurations"
        case skipTestConfigurations = "skip_test_configurations"
        case metadata
    }
}

private struct RunProfileMetadata: Codable, Sendable {
    var name: String
    var repoRoot: String
    var projectPath: String?
    var workspacePath: String?
    var scheme: String
    var resetPolicy: String?
    var defaultTestPlan: String?
    var parallel: ParallelSettings
    var ports: PortRangeSettings?
    var xctestTimeouts: XCTestTimeoutSettings
    var xctestRetries: XCTestRetrySettings
    var xctestDiagnostics: XCTestDiagnosticSettings
    var destination: XcodeDestinationSettings
    var coverage: CodeCoverageSettings
    var resultStream: ResultStreamSettings
    var resultBundle: ResultBundleSettings
    var testProducts: TestProductsSettings
    var privacy: SimulatorPrivacySettings

    enum CodingKeys: String, CodingKey {
        case name
        case repoRoot = "repo_root"
        case projectPath = "project_path"
        case workspacePath = "workspace_path"
        case scheme
        case resetPolicy = "reset_policy"
        case defaultTestPlan = "default_test_plan"
        case parallel
        case ports
        case xctestTimeouts = "xctest_timeouts"
        case xctestRetries = "xctest_retries"
        case xctestDiagnostics = "xctest_diagnostics"
        case destination
        case coverage
        case resultStream = "result_stream"
        case resultBundle = "result_bundle"
        case testProducts = "test_products"
        case privacy
    }
}

final class ResultReporter: @unchecked Sendable {
    private let environment: AppEnvironment
    private let junitWriter = JUnitReportWriter()
    private let xcresultReader: XCResultReader
    private let probeWarnings = ProbeWarningRecorder()

    init(environment: AppEnvironment) {
        self.environment = environment
        self.xcresultReader = XCResultReader(environment: environment) { [probeWarnings] warning in
            probeWarnings.record(warning)
        }
    }

    func persistSummary(_ summary: JobSummary, to url: URL) throws {
        try environment.fileSystem.writeData(try jsonData(summary), to: url)
    }

    func counts(from summary: XCResultSummary?) -> JobCounts? {
        summary.map {
            JobCounts(
                testsRun: $0.testsCount,
                testsFailed: $0.testsFailedCount,
                testsSkipped: $0.testsSkippedCount
            )
        }
    }

    func aggregateCounts(_ summaries: [XCResultSummary]) -> JobCounts? {
        guard !summaries.isEmpty else {
            return nil
        }
        return JobCounts(
            testsRun: summaries.reduce(0) { $0 + $1.testsCount },
            testsFailed: summaries.reduce(0) { $0 + $1.testsFailedCount },
            testsSkipped: summaries.reduce(0) { $0 + $1.testsSkippedCount }
        )
    }

    func parseXCResultSummary(at resultBundle: URL, context: ToolExecutionContext? = nil) -> XCResultSummary? {
        xcresultReader.summary(at: resultBundle, context: context)
    }

    func parseXCResultSummaryProbe(at resultBundle: URL, context: ToolExecutionContext? = nil) -> XCResultSummaryProbeResult {
        xcresultReader.summaryProbe(at: resultBundle, context: context)
    }

    func parseXCResultTestTimings(at resultBundle: URL, context: ToolExecutionContext? = nil) -> [TestTimingSample] {
        xcresultReader.testTimings(at: resultBundle, context: context)
    }

    func writeJUnitReport(
        project: String,
        resultClass: ResultClass,
        counts: JobCounts?,
        durationSeconds: Double,
        cases: [JUnitTestCase],
        outputURL: URL
    ) throws {
        let xml = junitWriter.xml(
            project: project,
            resultClass: resultClass,
            counts: counts,
            durationSeconds: durationSeconds,
            cases: cases
        )
        try environment.fileSystem.writeData(Data(xml.utf8), to: outputURL)
    }

    func junitCasesForSingleRun(
        resultClass: ResultClass,
        counts: JobCounts?,
        onlyTesting: [String]
    ) -> [JUnitTestCase] {
        junitWriter.casesForSingleRun(
            resultClass: resultClass,
            counts: counts,
            onlyTesting: onlyTesting
        )
    }

    func junitCasesForShardReports(_ reports: [ShardReport]) -> [JUnitTestCase] {
        junitWriter.casesForShardReports(reports)
    }

    func writeManualRunDiagnostics(
        resultClass: ResultClass,
        counts: JobCounts?,
        reports: [ShardReport],
        paths: ExecutionPaths,
        context: ToolExecutionContext
    ) throws {
        let diagnostics = ManualShardRunDiagnostics(
            jobID: context.jobID,
            project: context.profile.name,
            mode: context.profile.parallel.mode,
            resultClass: resultClass,
            shardCount: reports.count,
            retryCount: reports.filter { $0.attempts > 1 }.count,
            failedShardCount: reports.filter { $0.resultClass != .success }.count,
            counts: counts,
            mergedResultBundle: environment.fileSystem.fileExists(paths.mergedResultBundle)
                ? paths.mergedResultBundle.path
                : nil,
            shardsManifest: paths.shardsManifest.path,
            simulatorDiagnostics: reports.flatMap(\.simulatorDiagnostics),
            shards: reports
        )
        try environment.fileSystem.writeData(try jsonData(diagnostics), to: paths.combinedSummary)
    }

    func writeRunMetadata(
        summary: JobSummary,
        profile: ProjectProfile,
        request: JobRequest,
        paths: ExecutionPaths,
        includeToolProbes: Bool = true
    ) throws {
        guard let startedAt = summary.startedAt,
              let finishedAt = summary.finishedAt,
              let durationSeconds = summary.durationSeconds else {
            _ = probeWarnings.drain()
            return
        }
        let xcodebuildHelpPath = includeToolProbes ? captureXcodebuildHelp(profile: profile, paths: paths) : nil
        let xcodeVersion = includeToolProbes ? queryXcodeVersion(profile: profile) : nil
        let xcodebuildPath = includeToolProbes ? queryXcodebuildPath(profile: profile) : nil
        let commands = commandRecords(at: paths.commandLog)
        let warnings = probeWarnings.drain()
        let metadata = RunMetadata(
            jobID: summary.jobID,
            project: summary.project,
            state: summary.state,
            resultClass: summary.resultClass,
            simulatorID: summary.simulatorID ?? "",
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationSeconds: durationSeconds,
            xcodeVersion: xcodeVersion,
            xcodebuildPath: xcodebuildPath,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            exitCode: summary.exitCode,
            timedOut: commands.contains { $0.timedOut } || summary.resultClass == .buildTimeout || summary.resultClass == .testTimeout,
            canceled: summary.state == .canceled || summary.resultClass == .canceled,
            request: RunRequestMetadata(
                testPlan: request.testPlan ?? profile.defaultTestPlan,
                onlyTesting: request.onlyTesting,
                skipTesting: request.skipTesting,
                onlyTestConfigurations: request.onlyTestConfigurations,
                skipTestConfigurations: request.skipTestConfigurations,
                metadata: request.metadata
            ),
            profile: RunProfileMetadata(
                name: profile.name,
                repoRoot: profile.repoRoot,
                projectPath: profile.projectPath,
                workspacePath: profile.workspacePath,
                scheme: profile.scheme,
                resetPolicy: profile.resetPolicy,
                defaultTestPlan: profile.defaultTestPlan,
                parallel: profile.parallel,
                ports: profile.ports,
                xctestTimeouts: profile.xctestTimeouts,
                xctestRetries: profile.xctestRetries,
                xctestDiagnostics: profile.xctestDiagnostics,
                destination: profile.destination,
                coverage: profile.coverage,
                resultStream: profile.resultStream,
                resultBundle: profile.resultBundle,
                testProducts: profile.testProducts,
                privacy: profile.privacy
            ),
            artifacts: summary.artifacts,
            derivedDataPath: summary.artifacts.derivedData,
            resultBundlePath: summary.artifacts.xcresult,
            summaryPath: paths.summary.path,
            commandLogPath: environment.fileSystem.fileExists(paths.commandLog) ? paths.commandLog.path : nil,
            commandEventLogPath: environment.fileSystem.fileExists(paths.commandEventLog) ? paths.commandEventLog.path : nil,
            combinedLogPath: summary.artifacts.combinedLog,
            buildLogPath: summary.artifacts.buildLog,
            testLogPath: summary.artifacts.testLog,
            junitPath: summary.artifacts.junit,
            testProductsPath: environment.fileSystem.fileExists(paths.testProducts) ? paths.testProducts.path : nil,
            resultStreamPath: environment.fileSystem.fileExists(paths.resultStream) ? paths.resultStream.path : nil,
            xcodebuildHelpPath: xcodebuildHelpPath,
            commands: commands,
            attempts: attemptArtifacts(at: paths.attemptsRoot),
            probeWarnings: warnings
        )
        try environment.fileSystem.writeData(try jsonData(metadata), to: paths.runMetadata)
    }

    private func commandRecords(at commandLog: URL) -> [RunCommandRecord] {
        guard let data = try? environment.fileSystem.readData(from: commandLog),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text
            .split(separator: "\n")
            .compactMap { line in
                try? decodeJSON(RunCommandRecord.self, from: Data(line.utf8))
            }
    }

    private func attemptArtifacts(at attemptsRoot: URL) -> [AttemptArtifact] {
        guard let entries = try? environment.fileSystem.contentsOfDirectory(attemptsRoot) else {
            return []
        }
        return entries
            .compactMap { entry -> AttemptArtifact? in
                let metadata = entry.appendingPathComponent("attempt-metadata.json")
                guard let data = try? environment.fileSystem.readData(from: metadata) else {
                    return nil
                }
                return try? decodeJSON(AttemptArtifact.self, from: data)
            }
            .sorted { $0.attempt < $1.attempt }
    }

    private func captureXcodebuildHelp(profile: ProjectProfile, paths: ExecutionPaths) -> String? {
        let command = ["xcodebuild", "-help"]
        let result = runXcodebuildHelpProbe(profile: profile, command: command)
        guard let result else {
            return nil
        }
        guard result.exitCode == 0, !result.timedOut else {
            recordProbeWarning(
                source: "xcodebuild.help",
                command: command,
                message: result.timedOut
                    ? "xcodebuild -help probe timed out"
                    : "xcodebuild -help probe failed with exit code \(result.exitCode)",
                result: result
            )
            return nil
        }
        do {
            try environment.fileSystem.writeData(Data(result.output.utf8), to: paths.xcodebuildHelp)
            return paths.xcodebuildHelp.path
        } catch {
            recordProbeWarning(
                source: "xcodebuild.help",
                command: command,
                message: "xcodebuild -help probe output could not be written: \(error)",
                result: result
            )
            return nil
        }
    }

    private func runXcodebuildHelpProbe(profile: ProjectProfile, command: [String]) -> ToolResult? {
        let timeouts: [TimeInterval] = [5, 30]
        for timeout in timeouts {
            let result: ToolResult
            do {
                result = try environment.toolRunner.run(
                    tool: "xcodebuild",
                    arguments: ["-help"],
                    environment: profile.env,
                    workingDirectory: profile.workingDirectory,
                    timeout: timeout
                )
            } catch {
                recordProbeWarning(
                    source: "xcodebuild.help",
                    command: command,
                    message: "xcodebuild -help probe could not run: \(error)"
                )
                return nil
            }
            if result.timedOut, timeout != timeouts.last {
                continue
            }
            return result
        }
        return nil
    }

    private func queryXcodeVersion(profile: ProjectProfile) -> String? {
        let command = ["xcodebuild", "-version"]
        let result: ToolResult
        do {
            result = try environment.toolRunner.run(
                tool: "xcodebuild",
                arguments: ["-version"],
                environment: profile.env,
                workingDirectory: profile.workingDirectory,
                timeout: 10
            )
        } catch {
            recordProbeWarning(
                source: "xcodebuild.version",
                command: command,
                message: "xcodebuild -version probe could not run: \(error)"
            )
            return nil
        }
        guard result.exitCode == 0, !result.timedOut else {
            recordProbeWarning(
                source: "xcodebuild.version",
                command: command,
                message: result.timedOut
                    ? "xcodebuild -version probe timed out"
                    : "xcodebuild -version probe failed with exit code \(result.exitCode)",
                result: result
            )
            return nil
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.contains("Xcode") else {
            recordProbeWarning(
                source: "xcodebuild.version",
                command: command,
                message: "xcodebuild -version probe produced unparseable output",
                result: result
            )
            return nil
        }
        return output
    }

    private func queryXcodebuildPath(profile: ProjectProfile) -> String? {
        let command = ["xcrun", "--find", "xcodebuild"]
        let result: ToolResult
        do {
            result = try environment.toolRunner.run(
                tool: "xcrun",
                arguments: ["--find", "xcodebuild"],
                environment: profile.env,
                workingDirectory: profile.workingDirectory,
                timeout: 5
            )
        } catch {
            recordProbeWarning(
                source: "xcodebuild.path",
                command: command,
                message: "xcrun --find xcodebuild probe could not run: \(error)"
            )
            return nil
        }
        guard result.exitCode == 0, !result.timedOut else {
            recordProbeWarning(
                source: "xcodebuild.path",
                command: command,
                message: result.timedOut
                    ? "xcrun --find xcodebuild probe timed out"
                    : "xcrun --find xcodebuild probe failed with exit code \(result.exitCode)",
                result: result
            )
            return nil
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            recordProbeWarning(
                source: "xcodebuild.path",
                command: command,
                message: "xcrun --find xcodebuild probe produced empty output",
                result: result
            )
            return nil
        }
        return output
    }

    private func recordProbeWarning(
        source: String,
        command: [String],
        message: String,
        result: ToolResult? = nil
    ) {
        probeWarnings.record(ProbeWarning(
            source: source,
            command: command.joined(separator: " "),
            message: message,
            exitCode: result?.exitCode,
            timedOut: result?.timedOut,
            outputExcerpt: result.flatMap { outputExcerpt($0.output) }
        ))
    }

    private func outputExcerpt(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count <= 500 {
            return trimmed
        }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 500)
        return String(trimmed[..<end])
    }

}
