import Darwin
import Foundation

struct ExecutorContext {
    let environment: AppEnvironment
    let store: StateStore
    let profile: ProjectProfile
    let job: JobRecord
}

struct XCResultSummary: Decodable {
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

private struct ToolExecutionContext {
    let profile: ProjectProfile
    let jobID: String
    let store: StateStore
}

private struct TestOutcome {
    var resultClass: ResultClass
    var exitCode: Int32?
}

private struct ExecutionPaths {
    let jobRoot: URL
    let logsRoot: URL
    let artifactsRoot: URL
    let derivedData: URL
    let buildLog: URL
    let testLog: URL
    let combinedLog: URL
    let resultBundle: URL
    let summary: URL

    init(job: JobRecord) {
        self.jobRoot = URL(fileURLWithPath: job.jobDirectory)
        self.logsRoot = jobRoot.appendingPathComponent("logs")
        self.artifactsRoot = jobRoot.appendingPathComponent("artifacts")
        self.derivedData = jobRoot.appendingPathComponent("derived-data")
        self.buildLog = logsRoot.appendingPathComponent("build.log")
        self.testLog = logsRoot.appendingPathComponent("test.log")
        self.combinedLog = logsRoot.appendingPathComponent("combined.log")
        self.resultBundle = artifactsRoot.appendingPathComponent("result.xcresult")
        self.summary = artifactsRoot.appendingPathComponent("summary.json")
    }

    func createDirectories(using fileSystem: FileSystem) throws {
        try fileSystem.createDirectory(logsRoot)
        try fileSystem.createDirectory(artifactsRoot)
        try fileSystem.createDirectory(derivedData)
    }

    func artifacts(fileSystem: FileSystem) -> JobArtifacts {
        JobArtifacts(
            xcresult: fileSystem.fileExists(resultBundle) ? resultBundle.path : nil,
            combinedLog: combinedLog.path,
            buildLog: buildLog.path,
            testLog: testLog.path,
            derivedData: derivedData.path,
            diagnostics: nil
        )
    }

    var initialArtifacts: JobArtifacts {
        JobArtifacts(
            xcresult: nil,
            combinedLog: combinedLog.path,
            buildLog: buildLog.path,
            testLog: testLog.path,
            derivedData: derivedData.path,
            diagnostics: nil
        )
    }
}

final class JobExecutor {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func execute(job: JobRecord, profile: ProjectProfile, store: StateStore) throws -> JobSummary {
        let paths = ExecutionPaths(job: job)
        try paths.createDirectories(using: environment.fileSystem)
        var simulatorID: String?
        var startedAt: Double?

        do {
            let jobStart = environment.clock.now().timeIntervalSince1970
            startedAt = jobStart
            try store.updateJob(id: job.id, patch: JobStatePatch(state: .running, startedAt: jobStart))
            try store.updateLeaseHeartbeat(jobID: job.id)
            let toolContext = ToolExecutionContext(profile: profile, jobID: job.id, store: store)

            let resolvedSimulatorID = try resolveSimulatorID(request: job.request, context: toolContext)
            simulatorID = resolvedSimulatorID
            try store.updateJob(id: job.id, patch: JobStatePatch(state: .running, simulatorID: resolvedSimulatorID))

            if try isCancelRequested(context: toolContext) {
                return try finishCanceled(
                    job: job,
                    profile: profile,
                    paths: paths,
                    startedAt: jobStart,
                    simulatorID: resolvedSimulatorID,
                    artifacts: paths.initialArtifacts
                )
            }
            if let message = try competingRunnerMessage() {
                _ = try failAndLog(message: message, exitCode: 75, logURL: paths.buildLog, combinedLog: paths.combinedLog)
                return try finish(
                    job: job,
                    profile: profile,
                    paths: paths,
                    state: .failed,
                    resultClass: .runnerBootstrapFailure,
                    exitCode: 75,
                    startedAt: jobStart,
                    simulatorID: resolvedSimulatorID,
                    artifacts: paths.initialArtifacts
                )
            }
            try bootSimulator(simulatorID: resolvedSimulatorID, context: toolContext)
            if try isCancelRequested(context: toolContext) {
                return try finishCanceled(
                    job: job,
                    profile: profile,
                    paths: paths,
                    startedAt: jobStart,
                    simulatorID: resolvedSimulatorID,
                    artifacts: paths.initialArtifacts
                )
            }

            let buildResult = try runBuild(simulatorID: resolvedSimulatorID, paths: paths, request: job.request, context: toolContext)
            let cancelAfterBuild = try isCancelRequested(context: toolContext)
            if cancelAfterBuild && isCancellationResult(buildResult) {
                return try finishCanceled(
                    job: job,
                    profile: profile,
                    paths: paths,
                    exitCode: buildResult.exitCode,
                    startedAt: jobStart,
                    simulatorID: resolvedSimulatorID,
                    artifacts: paths.initialArtifacts
                )
            }
            if buildResult.exitCode != 0 || buildResult.timedOut {
                return try finish(
                    job: job,
                    profile: profile,
                    paths: paths,
                    state: .failed,
                    resultClass: .buildFailure,
                    exitCode: buildResult.exitCode,
                    startedAt: jobStart,
                    simulatorID: resolvedSimulatorID,
                    artifacts: paths.initialArtifacts
                )
            }
            if cancelAfterBuild {
                return try finishCanceled(
                    job: job,
                    profile: profile,
                    paths: paths,
                    exitCode: buildResult.exitCode,
                    startedAt: jobStart,
                    simulatorID: resolvedSimulatorID,
                    artifacts: paths.initialArtifacts
                )
            }

            let testOutcome = try runTestWithRetryIfNeeded(simulatorID: resolvedSimulatorID, paths: paths, request: job.request, context: toolContext)
            let finishedAt = environment.clock.now().timeIntervalSince1970
            let artifacts = paths.artifacts(fileSystem: environment.fileSystem)
            let parsedSummary = parseXCResultSummary(at: paths.resultBundle)
            let resultClass = testOutcome.resultClass == .success && parsedSummary == nil
                ? ResultClass.artifactFailure
                : testOutcome.resultClass
            return try finish(
                job: job,
                profile: profile,
                paths: paths,
                state: state(for: resultClass),
                resultClass: resultClass,
                exitCode: testOutcome.exitCode,
                startedAt: jobStart,
                finishedAt: finishedAt,
                simulatorID: resolvedSimulatorID,
                counts: counts(from: parsedSummary),
                artifacts: artifacts
            )
        } catch {
            if isCancellationError(error) {
                let failureStartedAt = startedAt ?? environment.clock.now().timeIntervalSince1970
                let failureArtifacts = paths.artifacts(fileSystem: environment.fileSystem)
                return try finishCanceled(
                    job: job,
                    profile: profile,
                    paths: paths,
                    startedAt: failureStartedAt,
                    simulatorID: simulatorID ?? job.request.simulatorID ?? profile.defaultSimulatorID ?? "",
                    artifacts: failureArtifacts
                )
            }
            let resultClass = classifyUnhandled(error)
            let failureStartedAt = startedAt ?? environment.clock.now().timeIntervalSince1970
            let failureArtifacts = paths.artifacts(fileSystem: environment.fileSystem)
            _ = try? failAndLog(
                message: String(describing: error),
                exitCode: 75,
                logURL: paths.buildLog,
                combinedLog: paths.combinedLog
            )
            return try finish(
                job: job,
                profile: profile,
                paths: paths,
                state: .failed,
                resultClass: resultClass,
                exitCode: nil,
                startedAt: failureStartedAt,
                simulatorID: simulatorID ?? job.request.simulatorID ?? profile.defaultSimulatorID ?? "",
                artifacts: failureArtifacts,
                summaryLine: String(describing: error)
            )
        }
    }

    private func runBuild(simulatorID: String, paths: ExecutionPaths, request: JobRequest, context: ToolExecutionContext) throws -> ToolResult {
        let profile = context.profile
        var arguments = xcodebuildBaseArguments(profile: profile)
        arguments.append(contentsOf: [
            "-destination", "id=\(simulatorID)",
            "-parallel-testing-enabled", "NO",
            "-maximum-parallel-testing-workers", "1",
            "-derivedDataPath", paths.derivedData.path,
        ])
        if let testPlan = request.testPlan ?? profile.defaultTestPlan, !testPlan.isEmpty {
            arguments.append(contentsOf: ["-testPlan", testPlan])
        }
        arguments.append("build-for-testing")
        return try runAndLog(tool: "xcodebuild", arguments: arguments, timeout: profile.timeouts.build, logURL: paths.buildLog, combinedLog: paths.combinedLog, context: context)
    }

    private func runTestWithRetryIfNeeded(simulatorID: String, paths: ExecutionPaths, request: JobRequest, context: ToolExecutionContext) throws -> TestOutcome {
        let run = try runTest(simulatorID: simulatorID, paths: paths, request: request, context: context)
        if try isCancelRequested(context: context), isCancellationResult(run) {
            return TestOutcome(resultClass: .canceled, exitCode: run.exitCode)
        }
        if shouldRetryBootstrapFailure(run: run) {
            let shutdown = try runTool(tool: "xcrun", arguments: ["simctl", "shutdown", simulatorID], timeout: context.profile.timeouts.boot, context: context)
            try throwIfCanceled(shutdown, context: context)
            let erase = try runTool(tool: "xcrun", arguments: ["simctl", "erase", simulatorID], timeout: context.profile.timeouts.boot, context: context)
            try throwIfCanceled(erase, context: context)
            try bootSimulator(simulatorID: simulatorID, context: context)
            let retry = try runTest(simulatorID: simulatorID, paths: paths, request: request, context: context)
            if try isCancelRequested(context: context), isCancellationResult(retry) {
                return TestOutcome(resultClass: .canceled, exitCode: retry.exitCode)
            }
            return classify(run: retry, resultBundle: paths.resultBundle)
        }
        return classify(run: run, resultBundle: paths.resultBundle)
    }

    private func runTest(simulatorID: String, paths: ExecutionPaths, request: JobRequest, context: ToolExecutionContext) throws -> ToolResult {
        let profile = context.profile
        if environment.fileSystem.fileExists(paths.resultBundle) {
            try environment.fileSystem.removeItem(paths.resultBundle)
        }
        guard let xctestrunPath = resolveXCTestRunPath(in: paths.derivedData, preferredTestPlan: request.testPlan ?? profile.defaultTestPlan) else {
            return try failAndLog(
                message: "No .xctestrun file was generated under \(paths.derivedData.appendingPathComponent("Build/Products").path)",
                exitCode: 70,
                logURL: paths.testLog,
                combinedLog: paths.combinedLog
            )
        }
        var arguments = [
            "-xctestrun", xctestrunPath.path,
            "-destination", "id=\(simulatorID)",
            "-parallel-testing-enabled", "NO",
            "-maximum-parallel-testing-workers", "1",
            "-resultBundlePath", paths.resultBundle.path,
        ]
        for onlyTesting in request.onlyTesting {
            arguments.append("-only-testing:\(onlyTesting)")
        }
        arguments.append("test-without-building")
        return try runAndLog(tool: "xcodebuild", arguments: arguments, timeout: profile.timeouts.test, logURL: paths.testLog, combinedLog: paths.combinedLog, context: context)
    }

    private func resolveSimulatorID(request: JobRequest, context: ToolExecutionContext) throws -> String {
        let profile = context.profile
        if let requestedSimulatorID = request.simulatorID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedSimulatorID.isEmpty {
            if !profile.allowedSimulatorIDs.isEmpty,
               !profile.allowedSimulatorIDs.contains(requestedSimulatorID),
               requestedSimulatorID != profile.defaultSimulatorID {
                throw XCStewardError.invalidConfiguration("Requested simulator override \(requestedSimulatorID) is not allowed by profile \(profile.name)")
            }
            return requestedSimulatorID
        }
        if let defaultSimulatorID = profile.defaultSimulatorID {
            return defaultSimulatorID
        }
        if let managed = profile.managedSimulator {
            let list = try runTool(tool: "xcrun", arguments: ["simctl", "list", "devices"], timeout: profile.timeouts.boot, context: context)
            try throwIfCanceled(list, context: context)
            if list.exitCode != 0 || list.timedOut {
                throw commandFailed("Unable to list simulators for managed simulator '\(managed.name)'", output: list.output)
            }
            if let match = parseSimulatorID(from: list.output, preferredName: managed.name) {
                return match
            }
            let create = try runTool(tool: "xcrun", arguments: ["simctl", "create", managed.name, managed.deviceType, managed.runtime], timeout: profile.timeouts.boot, context: context)
            try throwIfCanceled(create, context: context)
            if create.exitCode != 0 || create.timedOut {
                throw commandFailed("Unable to create managed simulator '\(managed.name)'", output: create.output)
            }
            if let created = parseCreatedSimulatorID(from: create.output) {
                return created
            }
            throw commandFailed("Unable to create managed simulator '\(managed.name)': expected a single simulator UDID in simctl create output", output: create.output)
        }
        throw XCStewardError.invalidConfiguration("Profile \(profile.name) has no simulator assignment")
    }

    private func classify(run: ToolResult, resultBundle: URL) -> TestOutcome {
        if run.timedOut {
            return TestOutcome(
                resultClass: isRunnerBootstrapFailure(run: run) ? .runnerBootstrapFailure : .testTimeout,
                exitCode: run.exitCode
            )
        }
        if run.exitCode == 0 {
            return TestOutcome(
                resultClass: environment.fileSystem.fileExists(resultBundle) ? .success : .artifactFailure,
                exitCode: 0
            )
        }
        if isRunnerConfigurationFailure(run: run) {
            return TestOutcome(resultClass: .runnerBootstrapFailure, exitCode: run.exitCode)
        }
        if !environment.fileSystem.fileExists(resultBundle) {
            return TestOutcome(resultClass: .artifactFailure, exitCode: run.exitCode)
        }
        return TestOutcome(resultClass: .testFailure, exitCode: run.exitCode)
    }

    private func state(for resultClass: ResultClass) -> JobState {
        switch resultClass {
        case .success:
            return .succeeded
        case .canceled:
            return .canceled
        case .buildFailure, .testFailure, .testTimeout, .runnerBootstrapFailure, .artifactFailure, .internalError:
            return .failed
        }
    }

    private func counts(from summary: XCResultSummary?) -> JobCounts? {
        summary.map {
            JobCounts(
                testsRun: $0.testsCount,
                testsFailed: $0.testsFailedCount,
                testsSkipped: $0.testsSkippedCount
            )
        }
    }

    private func commandFailed(_ message: String, output: String) -> XCStewardError {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(detail.isEmpty ? message : "\(message): \(detail)")
    }

    private func shouldRetryBootstrapFailure(run: ToolResult) -> Bool {
        isRunnerBootstrapFailure(run: run)
    }

    private func isRunnerBootstrapFailure(run: ToolResult) -> Bool {
        let patterns = [
            "Failed to background test runner",
            "operation never finished bootstrapping",
            "Lost connection to testmanagerd",
            "Early unexpected exit",
        ]
        return patterns.contains(where: { run.output.contains($0) })
    }

    private func isRunnerConfigurationFailure(run: ToolResult) -> Bool {
        let patterns = [
            "Failed to background test runner",
            "operation never finished bootstrapping",
            "Lost connection to testmanagerd",
            "Early unexpected exit",
            "There are no test bundles available to test.",
            "does not have an associated test plan named",
            "Unable to find a device matching the provided destination specifier",
            "No .xctestrun file was generated under",
        ]
        return patterns.contains(where: { run.output.contains($0) })
    }

    private func parseXCResultSummary(at resultBundle: URL) -> XCResultSummary? {
        guard environment.fileSystem.fileExists(resultBundle) else {
            return nil
        }
        guard let tool = try? environment.toolRunner.run(
            tool: "xcrun",
            arguments: ["xcresulttool", "get", "test-results", "summary", "--path", resultBundle.path],
            environment: [:],
            workingDirectory: nil,
            timeout: 30
        ) else {
            return nil
        }
        guard tool.exitCode == 0, let data = tool.output.data(using: .utf8) else {
            return nil
        }
        return try? decodeJSON(XCResultSummary.self, from: data)
    }

    private func runAndLog(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext
    ) throws -> ToolResult {
        let result = try runTool(tool: tool, arguments: arguments, timeout: timeout, context: context)
        try environment.fileSystem.writeData(Data(result.output.utf8), to: logURL)
        try environment.fileSystem.appendData(Data(result.output.utf8), to: combinedLog)
        return result
    }

    private func runTool(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext
    ) throws -> ToolResult {
        defer {
            try? context.store.clearJobProcessID(id: context.jobID)
        }
        return try environment.toolRunner.run(
            tool: tool,
            arguments: arguments,
            environment: context.profile.env,
            workingDirectory: context.profile.workingDirectory,
            timeout: timeout,
            processStarted: { pid in
                try context.store.updateJob(id: context.jobID, patch: JobStatePatch(state: .running, processID: pid))
            }
        )
    }

    private func failAndLog(message: String, exitCode: Int32, logURL: URL, combinedLog: URL) throws -> ToolResult {
        let output = message.hasSuffix("\n") ? message : "\(message)\n"
        let data = Data(output.utf8)
        try environment.fileSystem.writeData(data, to: logURL)
        try environment.fileSystem.appendData(data, to: combinedLog)
        return ToolResult(exitCode: exitCode, output: output, timedOut: false)
    }

    private func competingRunnerMessage() throws -> String? {
        let processes: ToolResult
        do {
            processes = try environment.toolRunner.run(
                tool: "ps",
                arguments: ["-Ao", "pid,command"],
                environment: [:],
                workingDirectory: nil,
                timeout: 5
            )
        } catch {
            return nil
        }
        guard processes.exitCode == 0 else {
            return nil
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let competingProcess = RunnerProcessDetector.records(from: processes.output)
            .first { process in
                process.pid != currentPID &&
                    RunnerProcessDetector.isCompeting(command: process.command, policy: .executor)
            }

        guard let competingProcess else {
            return nil
        }
        return "Competing simulator-hosted test activity detected: \(competingProcess.command)"
    }

    private func bootSimulator(simulatorID: String, context: ToolExecutionContext) throws {
        let profile = context.profile
        let boot = try runSimulatorBoot(simulatorID: simulatorID, context: context)
        let alreadyBooted = boot.output.contains("current state: Booted")

        do {
            try confirmBootStatus(
                simulatorID: simulatorID,
                timeout: alreadyBooted ? profile.timeouts.boot : max(profile.timeouts.boot, 240),
                context: context
            )
        } catch {
            guard alreadyBooted,
                  String(describing: error).contains("Unable to confirm simulator boot status") else {
                throw error
            }
            let shutdown = try runTool(
                tool: "xcrun",
                arguments: ["simctl", "shutdown", simulatorID],
                timeout: profile.timeouts.boot,
                context: context
            )
            try throwIfCanceled(shutdown, context: context)
            _ = try runSimulatorBoot(simulatorID: simulatorID, context: context)
            try confirmBootStatus(
                simulatorID: simulatorID,
                timeout: max(profile.timeouts.boot, 240),
                context: context
            )
        }
    }

    private func runSimulatorBoot(simulatorID: String, context: ToolExecutionContext) throws -> ToolResult {
        let boot = try runTool(
            tool: "xcrun",
            arguments: ["simctl", "boot", simulatorID],
            timeout: context.profile.timeouts.boot,
            context: context
        )
        try throwIfCanceled(boot, context: context)
        if boot.exitCode != 0 && !boot.output.contains("current state: Booted") {
            throw XCStewardError.commandFailed("Unable to boot simulator \(simulatorID)")
        }
        return boot
    }

    private func confirmBootStatus(simulatorID: String, timeout: TimeInterval, context: ToolExecutionContext) throws {
        let bootStatus = try runTool(
            tool: "xcrun",
            arguments: ["simctl", "bootstatus", simulatorID, "-b"],
            timeout: timeout,
            context: context
        )
        try throwIfCanceled(bootStatus, context: context)
        guard bootStatus.exitCode == 0, !bootStatus.timedOut else {
            throw bootStatusError(simulatorID: simulatorID, result: bootStatus)
        }
    }

    private func bootStatusError(simulatorID: String, result: ToolResult) -> XCStewardError {
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return .commandFailed("Unable to confirm simulator boot status for \(simulatorID)")
        }
        return .commandFailed("Unable to confirm simulator boot status for \(simulatorID): \(detail)")
    }

    private func xcodebuildBaseArguments(profile: ProjectProfile) -> [String] {
        if let projectPath = profile.projectPath {
            return ["-project", URL(fileURLWithPath: profile.repoRoot).appendingPathComponent(projectPath).path, "-scheme", profile.scheme]
        }
        if let workspacePath = profile.workspacePath {
            return ["-workspace", URL(fileURLWithPath: profile.repoRoot).appendingPathComponent(workspacePath).path, "-scheme", profile.scheme]
        }
        return ["-scheme", profile.scheme]
    }

    private func finishCanceled(
        job: JobRecord,
        profile: ProjectProfile,
        paths: ExecutionPaths,
        exitCode: Int32? = nil,
        startedAt: Double,
        simulatorID: String,
        artifacts: JobArtifacts
    ) throws -> JobSummary {
        try finish(
            job: job,
            profile: profile,
            paths: paths,
            state: .canceled,
            resultClass: .canceled,
            exitCode: exitCode,
            startedAt: startedAt,
            simulatorID: simulatorID,
            artifacts: artifacts
        )
    }

    private func finish(
        job: JobRecord,
        profile: ProjectProfile,
        paths: ExecutionPaths,
        state: JobState,
        resultClass: ResultClass,
        exitCode: Int32?,
        startedAt: Double,
        finishedAt: Double? = nil,
        simulatorID: String,
        counts: JobCounts? = nil,
        artifacts: JobArtifacts,
        summaryLine: String? = nil
    ) throws -> JobSummary {
        let finishedAt = finishedAt ?? environment.clock.now().timeIntervalSince1970
        let summary = makeSummary(
            job: job,
            state: state,
            resultClass: resultClass,
            exitCode: exitCode,
            startedAt: startedAt,
            finishedAt: finishedAt,
            testPlan: job.request.testPlan ?? profile.defaultTestPlan,
            onlyTesting: job.request.onlyTesting,
            simulatorID: simulatorID,
            counts: counts,
            artifacts: artifacts,
            summaryLine: summaryLine ?? self.summaryLine(for: resultClass)
        )
        try persistSummary(summary, to: paths.summary)
        return summary
    }

    private func makeSummary(
        job: JobRecord,
        state: JobState,
        resultClass: ResultClass,
        exitCode: Int32?,
        startedAt: Double,
        finishedAt: Double,
        testPlan: String?,
        onlyTesting: [String],
        simulatorID: String,
        counts: JobCounts?,
        artifacts: JobArtifacts,
        summaryLine: String
    ) -> JobSummary {
        JobSummary(
            jobID: job.id,
            project: job.project,
            state: state,
            resultClass: resultClass,
            exitCode: exitCode,
            submittedAt: job.createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationSeconds: finishedAt - startedAt,
            testPlan: testPlan,
            onlyTesting: onlyTesting,
            simulatorID: simulatorID,
            counts: counts,
            artifacts: artifacts,
            summaryLine: summaryLine,
            metadata: job.request.metadata
        )
    }

    private func summaryLine(for resultClass: ResultClass) -> String {
        switch resultClass {
        case .success:
            return "Tests succeeded"
        case .buildFailure:
            return "Build failed"
        case .runnerBootstrapFailure:
            return "Runner failed before tests executed"
        case .artifactFailure:
            return "Artifacts were missing or invalid"
        case .testTimeout:
            return "Tests timed out"
        case .testFailure:
            return "Tests failed"
        case .canceled:
            return "Canceled"
        case .internalError:
            return "Internal error"
        }
    }

    private func persistSummary(_ summary: JobSummary, to url: URL) throws {
        try environment.fileSystem.writeData(try jsonData(summary), to: url)
    }

    private func isCancelRequested(context: ToolExecutionContext) throws -> Bool {
        try context.store.fetchJob(id: context.jobID)?.cancelRequested == true
    }

    private func throwIfCanceled(_ result: ToolResult, context: ToolExecutionContext) throws {
        if isCancellationResult(result), try isCancelRequested(context: context) {
            throw XCStewardError.canceled("Canceled")
        }
    }

    private func isCancellationResult(_ result: ToolResult) -> Bool {
        !result.timedOut && (result.exitCode == 128 + SIGTERM || result.exitCode == 128 + SIGKILL)
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if case XCStewardError.canceled = error {
            return true
        }
        return false
    }

    private func resolveXCTestRunPath(in derivedData: URL, preferredTestPlan: String?) -> URL? {
        let productsRoot = derivedData.appendingPathComponent("Build/Products")
        guard let entries = try? environment.fileSystem.contentsOfDirectory(productsRoot) else {
            return nil
        }
        let candidates = entries
            .filter { $0.pathExtension == "xctestrun" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !candidates.isEmpty else {
            return nil
        }
        if let preferredTestPlan, !preferredTestPlan.isEmpty {
            let normalizedPlan = preferredTestPlan.replacingOccurrences(of: " ", with: "")
            if let planMatch = candidates.first(where: {
                $0.lastPathComponent.localizedCaseInsensitiveContains(preferredTestPlan) ||
                $0.lastPathComponent.localizedCaseInsensitiveContains(normalizedPlan)
            }) {
                return planMatch
            }
        }
        return candidates.first
    }

    private func parseSimulatorID(from output: String, preferredName: String?) -> String? {
        for line in output.split(separator: "\n") {
            let string = String(line)
            if let preferredName, !string.contains(preferredName) { continue }
            var searchStart = string.startIndex
            while let open = string[searchStart...].firstIndex(of: "("),
                  let close = string[open...].dropFirst().firstIndex(of: ")") {
                let candidate = String(string[string.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty && !isSimulatorStatus(candidate) {
                    return candidate
                }
                searchStart = string.index(after: close)
            }
        }
        return nil
    }

    private func parseCreatedSimulatorID(from output: String) -> String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, isSimulatorUDID(lines[0]) else {
            return nil
        }
        return lines[0]
    }

    private func isSimulatorUDID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        let expectedLengths = [8, 4, 4, 4, 12]
        guard parts.count == expectedLengths.count else {
            return false
        }
        for (part, expectedLength) in zip(parts, expectedLengths) {
            guard part.count == expectedLength,
                  part.allSatisfy({ $0.isHexDigit }) else {
                return false
            }
        }
        return true
    }

    private func isSimulatorStatus(_ value: String) -> Bool {
        let statuses: Set<String> = [
            "Shutdown",
            "Booted",
            "Creating",
            "Shutting Down",
        ]
        return statuses.contains(value)
    }

    private func classifyUnhandled(_ error: Error) -> ResultClass {
        let description = String(describing: error)
        let runnerPatterns = [
            "Unable to boot simulator",
            "Unable to confirm simulator boot status",
            "Unable to list simulators",
            "Unable to create managed simulator",
            "Unable to resolve executable",
            "Competing simulator-hosted test activity",
        ]
        return runnerPatterns.contains { description.contains($0) }
            ? .runnerBootstrapFailure
            : .internalError
    }
}
