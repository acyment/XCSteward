import Darwin
import Foundation

final class JobExecutor: @unchecked Sendable {
    private let environment: AppEnvironment
    private let resultReporter: ResultReporter
    private let resultPolicy = ResultClassPolicy()
    private var simulatorLifecycle: SimulatorLifecycle {
        SimulatorLifecycle(environment: environment, tooling: self)
    }
    private var testOutcomeClassifier: TestOutcomeClassifier {
        TestOutcomeClassifier(resultBundleExists: environment.fileSystem.fileExists)
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.resultReporter = ResultReporter(environment: environment)
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
            let heartbeat = JobLeaseHeartbeat(environment: environment, jobID: job.id)
            heartbeat.start()
            defer { heartbeat.stop() }

            let resolvedSimulatorID = try resolveSimulatorID(request: job.request, context: toolContext)
            simulatorID = resolvedSimulatorID
            try store.updateJob(id: job.id, patch: JobStatePatch(state: .running, simulatorID: resolvedSimulatorID))
            guard try store.acquireSimulatorLease(simulatorID: resolvedSimulatorID, jobID: job.id, pid: getpid()) else {
                throw XCStewardError.commandFailed("Simulator \(resolvedSimulatorID) is already leased by another XCSteward job")
            }
            defer { try? store.releaseSimulatorLease(simulatorID: resolvedSimulatorID, jobID: job.id) }
            defer { cleanupSimulatorAfterJob(simulatorID: resolvedSimulatorID, context: toolContext) }

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
                try warnAndLog(message: message, logURL: paths.buildLog, combinedLog: paths.combinedLog)
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

            if profile.parallel.mode == .manualShards || profile.parallel.mode == .hybrid {
                let manualResult = try ManualShardRunner(
                    environment: environment,
                    runtime: self,
                    resultReporter: resultReporter
                ).run(
                    primarySimulatorID: resolvedSimulatorID,
                    paths: paths,
                    request: job.request,
                    context: toolContext
                )
                let finishedAt = environment.clock.now().timeIntervalSince1970
                return try finish(
                    job: job,
                    profile: profile,
                    paths: paths,
                    state: resultPolicy.terminalState(for: manualResult.resultClass),
                    resultClass: manualResult.resultClass,
                    exitCode: manualResult.exitCode,
                    startedAt: jobStart,
                    finishedAt: finishedAt,
                    simulatorID: resolvedSimulatorID,
                    counts: manualResult.counts,
                    artifacts: manualResult.artifacts,
                    summaryLine: manualResult.successSummaryLine
                )
            }

            let testOutcome = try runTestWithRetryIfNeeded(simulatorID: resolvedSimulatorID, paths: paths, request: job.request, context: toolContext)
            let finishedAt = environment.clock.now().timeIntervalSince1970
            let parsedSummary = resultReporter.parseXCResultSummary(at: paths.resultBundle)
            let resultClass = testOutcome.resultClass == .success && parsedSummary == nil
                ? ResultClass.artifactFailure
                : testOutcome.resultClass
            if resultClass.isInfrastructureFailure {
                _ = captureSimulatorDiagnostics(
                    simulatorID: resolvedSimulatorID,
                    outputURL: paths.simulatorDiagnostics,
                    context: toolContext
                )
            }
            let parsedCounts = resultReporter.counts(from: parsedSummary)
            try resultReporter.writeJUnitReport(
                project: profile.name,
                resultClass: resultClass,
                counts: parsedCounts,
                durationSeconds: finishedAt - jobStart,
                cases: resultReporter.junitCasesForSingleRun(
                    resultClass: resultClass,
                    counts: parsedCounts,
                    onlyTesting: job.request.onlyTesting
                ),
                outputURL: paths.junitReport
            )
            let artifacts = paths.artifacts(fileSystem: environment.fileSystem)
            return try finish(
                job: job,
                profile: profile,
                paths: paths,
                state: resultPolicy.terminalState(for: resultClass),
                resultClass: resultClass,
                exitCode: testOutcome.exitCode,
                startedAt: jobStart,
                finishedAt: finishedAt,
                simulatorID: resolvedSimulatorID,
                counts: parsedCounts,
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
            if resultClass.isInfrastructureFailure {
                let failureContext = ToolExecutionContext(profile: profile, jobID: job.id, store: store)
                _ = captureSimulatorDiagnostics(
                    simulatorID: simulatorID ?? job.request.simulatorID ?? profile.defaultSimulatorID ?? "",
                    outputURL: paths.simulatorDiagnostics,
                    context: failureContext
                )
            }
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
        let arguments = XcodebuildCommandBuilder(profile: profile).buildForTesting(
            simulatorID: simulatorID,
            paths: paths,
            request: request
        )
        return try runAndLog(
            tool: "xcodebuild",
            arguments: arguments,
            timeout: profile.timeouts.build,
            logURL: paths.buildLog,
            combinedLog: paths.combinedLog,
            context: context,
            environmentOverrides: xcodebuildEnvironment(
                context: context,
                temporaryDirectory: paths.temporaryRoot.appendingPathComponent("build"),
                phase: "build"
            )
        )
    }

    private func runTestWithRetryIfNeeded(simulatorID: String, paths: ExecutionPaths, request: JobRequest, context: ToolExecutionContext) throws -> TestOutcome {
        let run = try runTest(simulatorID: simulatorID, paths: paths, request: request, context: context)
        if try isCancelRequested(context: context), isCancellationResult(run) {
            return TestOutcome(resultClass: .canceled, exitCode: run.exitCode)
        }
        if shouldRetryBootstrapFailure(run: run) {
            try? context.store.recordInfrastructureEvent(
                jobID: context.jobID,
                simulatorID: simulatorID,
                resultClass: .runnerBootstrapFailure,
                message: "Retrying xcode-managed test after runner bootstrap failure"
            )
            _ = captureSimulatorDiagnostics(
                simulatorID: simulatorID,
                outputURL: paths.simulatorDiagnostics,
                context: context
            )
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
        guard let testReference = resolveTestProductReference(
            in: paths,
            preferredTestPlan: request.testPlan ?? profile.defaultTestPlan,
            context: context
        ) else {
            return try failAndLog(
                message: missingTestProductReferenceMessage(paths: paths, context: context),
                exitCode: 70,
                logURL: paths.testLog,
                combinedLog: paths.combinedLog
            )
        }
        try prepareSimulatorPrivacy(
            simulatorID: simulatorID,
            logURL: paths.testLog,
            combinedLog: paths.combinedLog,
            context: context
        )
        try prepareResultStreamIfNeeded(for: profile.resultStream, path: paths.resultStream)
        let arguments = XcodebuildCommandBuilder(profile: profile).xcodeManagedTest(
            testReference: testReference,
            simulatorID: simulatorID,
            paths: paths,
            request: request
        )
        return try runAndLog(
            tool: "xcodebuild",
            arguments: arguments,
            timeout: profile.timeouts.test,
            logURL: paths.testLog,
            combinedLog: paths.combinedLog,
            context: context,
            environmentOverrides: testRunnerEnvironment(
                context: context,
                temporaryDirectory: paths.temporaryRoot.appendingPathComponent("test"),
                phase: "test"
            )
        )
    }

    @discardableResult
    func captureSimulatorDiagnostics(
        simulatorID: String,
        outputURL: URL,
        context: ToolExecutionContext
    ) -> String? {
        simulatorLifecycle.captureDiagnostics(
            simulatorID: simulatorID,
            outputURL: outputURL,
            context: context
        )
    }

    func prepareSimulatorPrivacy(
        simulatorID: String,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext
    ) throws {
        try simulatorLifecycle.preparePrivacy(
            simulatorID: simulatorID,
            logURL: logURL,
            combinedLog: combinedLog,
            context: context
        )
    }

    func cleanupSimulatorAfterJob(simulatorID: String, context: ToolExecutionContext) {
        simulatorLifecycle.cleanupAfterJob(simulatorID: simulatorID, context: context)
    }

    func shutdownSimulatorForCloneTemplate(simulatorID: String, context: ToolExecutionContext) throws {
        try simulatorLifecycle.shutdownSimulatorForCloneTemplate(simulatorID: simulatorID, context: context)
    }

    func cloneManagedShardSimulator(
        templateSimulatorID: String,
        managed: ManagedSimulator,
        shardIndex: Int,
        context: ToolExecutionContext
    ) throws -> String {
        try simulatorLifecycle.cloneManagedShardSimulator(
            templateSimulatorID: templateSimulatorID,
            managed: managed,
            shardIndex: shardIndex,
            context: context
        )
    }

    func recoverSimulatorForShardRetry(simulatorID: String, context: ToolExecutionContext) throws {
        try simulatorLifecycle.recoverForShardRetry(simulatorID: simulatorID, context: context)
    }

    func deleteTransientSimulatorAfterJob(simulatorID: String, context: ToolExecutionContext) {
        simulatorLifecycle.deleteTransientSimulatorAfterJob(simulatorID: simulatorID, context: context)
    }

    private func resolveSimulatorID(request: JobRequest, context: ToolExecutionContext) throws -> String {
        try simulatorLifecycle.resolveSimulatorID(request: request, context: context)
    }

    func classify(run: ToolResult, resultBundle: URL) -> TestOutcome {
        testOutcomeClassifier.classify(run: run, resultBundle: resultBundle)
    }

    func commandFailed(_ message: String, output: String) -> XCStewardError {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(detail.isEmpty ? message : "\(message): \(detail)")
    }

    func shouldRetryBootstrapFailure(run: ToolResult) -> Bool {
        testOutcomeClassifier.shouldRetryBootstrapFailure(run: run)
    }

    private func xcodebuildEnvironment(
        context: ToolExecutionContext,
        temporaryDirectory: URL,
        phase: String
    ) -> [String: String] {
        [
            "TMPDIR": temporaryDirectory.path,
            "XCSTEWARD_JOB_ID": context.jobID,
            "XCSTEWARD_PROJECT": context.profile.name,
            "XCSTEWARD_PHASE": phase,
        ]
    }

    func testRunnerEnvironment(
        context: ToolExecutionContext,
        temporaryDirectory: URL,
        phase: String,
        shardID: String? = nil,
        shardIndex: Int? = nil,
        totalShards: Int? = nil
    ) -> [String: String] {
        var values = xcodebuildEnvironment(
            context: context,
            temporaryDirectory: temporaryDirectory,
            phase: phase
        )
        values["TEST_RUNNER_XCSTEWARD_JOB_ID"] = context.jobID
        values["TEST_RUNNER_XCSTEWARD_PROJECT"] = context.profile.name
        values["TEST_RUNNER_XCSTEWARD_PHASE"] = phase
        values["TEST_RUNNER_XCSTEWARD_MODE"] = context.profile.parallel.mode.rawValue
        applyPortRangeEnvironment(
            to: &values,
            settings: context.profile.ports,
            rangeIndex: shardIndex ?? 0
        )
        if let shardID {
            values["XCSTEWARD_SHARD_ID"] = shardID
            values["TEST_RUNNER_XCSTEWARD_SHARD_ID"] = shardID
        }
        if let shardIndex {
            values["XCSTEWARD_SHARD_INDEX"] = "\(shardIndex)"
            values["TEST_RUNNER_XCSTEWARD_SHARD_INDEX"] = "\(shardIndex)"
        }
        if let totalShards {
            values["XCSTEWARD_TOTAL_SHARDS"] = "\(totalShards)"
            values["TEST_RUNNER_XCSTEWARD_TOTAL_SHARDS"] = "\(totalShards)"
        }
        return values
    }

    private func applyPortRangeEnvironment(
        to values: inout [String: String],
        settings: PortRangeSettings?,
        rangeIndex: Int
    ) {
        guard let settings else {
            return
        }
        let start = settings.base + (rangeIndex * settings.stride)
        let end = start + settings.count - 1
        let range = "\(start)-\(end)"
        let portValues = [
            "XCSTEWARD_PORT_RANGE_INDEX": "\(rangeIndex)",
            "XCSTEWARD_PORT_RANGE_START": "\(start)",
            "XCSTEWARD_PORT_RANGE_END": "\(end)",
            "XCSTEWARD_PORT_RANGE_COUNT": "\(settings.count)",
            "XCSTEWARD_PORT_RANGE": range,
        ]
        for (key, value) in portValues {
            values[key] = value
            values["TEST_RUNNER_\(key)"] = value
        }
    }

    func runAndLog(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext,
        environmentOverrides: [String: String] = [:]
    ) throws -> ToolResult {
        let result = try runTool(
            tool: tool,
            arguments: arguments,
            timeout: timeout,
            context: context,
            environmentOverrides: environmentOverrides
        )
        try environment.fileSystem.appendData(Data(result.output.utf8), to: logURL)
        try environment.fileSystem.appendData(Data(result.output.utf8), to: combinedLog)
        return result
    }

    func runTool(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        environmentOverrides: [String: String] = [:]
    ) throws -> ToolResult {
        if let tmpdir = environmentOverrides["TMPDIR"], !tmpdir.isEmpty {
            try? environment.fileSystem.createDirectory(URL(fileURLWithPath: tmpdir))
        }
        defer {
            try? context.store.clearJobProcessID(id: context.jobID)
        }
        let toolEnvironment = context.profile.env.merging(environmentOverrides) { _, override in override }
        return try environment.toolRunner.run(
            tool: tool,
            arguments: arguments,
            environment: toolEnvironment,
            workingDirectory: context.profile.workingDirectory,
            timeout: timeout,
            processStarted: { pid in
                try context.store.updateJob(id: context.jobID, patch: JobStatePatch(state: .running, processID: pid))
            }
        )
    }

    func failAndLog(message: String, exitCode: Int32, logURL: URL, combinedLog: URL) throws -> ToolResult {
        let output = message.hasSuffix("\n") ? message : "\(message)\n"
        let data = Data(output.utf8)
        try environment.fileSystem.appendData(data, to: logURL)
        try environment.fileSystem.appendData(data, to: combinedLog)
        return ToolResult(exitCode: exitCode, output: output, timedOut: false)
    }

    func warnAndLog(message: String, logURL: URL, combinedLog: URL) throws {
        let output = "WARNING: \(message)\n"
        let data = Data(output.utf8)
        try environment.fileSystem.appendData(data, to: logURL)
        try environment.fileSystem.appendData(data, to: combinedLog)
    }

    func testIdentifier(_ identifier: String, matchesSkipFilter skipFilter: String) -> Bool {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let skipFilter = skipFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty, !skipFilter.isEmpty else {
            return false
        }
        return identifier == skipFilter || identifier.hasPrefix("\(skipFilter)/")
    }

    func prepareResultStreamIfNeeded(for settings: ResultStreamSettings, path: URL) throws {
        guard settings.enabled else {
            return
        }
        if environment.fileSystem.fileExists(path) {
            try environment.fileSystem.removeItem(path)
        }
        try environment.fileSystem.writeData(Data(), to: path)
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

    func bootSimulator(simulatorID: String, context: ToolExecutionContext) throws {
        try simulatorLifecycle.bootSimulator(simulatorID: simulatorID, context: context)
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
            summaryLine: summaryLine ?? resultPolicy.summaryLine(for: resultClass)
        )
        try resultReporter.persistSummary(summary, to: paths.summary)
        try? resultReporter.writeRunMetadata(
            summary: summary,
            profile: profile,
            request: job.request,
            paths: paths
        )
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

    private func isCancelRequested(context: ToolExecutionContext) throws -> Bool {
        try context.store.fetchJob(id: context.jobID)?.cancelRequested == true
    }

    func throwIfCanceled(_ result: ToolResult, context: ToolExecutionContext) throws {
        if isCancellationResult(result), try isCancelRequested(context: context) {
            throw XCStewardError.canceled("Canceled")
        }
    }

    func isCancellationResult(_ result: ToolResult) -> Bool {
        !result.timedOut && (result.exitCode == 128 + SIGTERM || result.exitCode == 128 + SIGKILL)
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if case XCStewardError.canceled = error {
            return true
        }
        return false
    }

    func resolveTestProductReference(
        in paths: ExecutionPaths,
        preferredTestPlan: String?,
        context: ToolExecutionContext
    ) -> TestProductReference? {
        if context.profile.testProducts.useForTesting {
            return environment.fileSystem.fileExists(paths.testProducts)
                ? .testProducts(paths.testProducts)
                : nil
        }
        return resolveXCTestRunPath(in: paths.derivedData, preferredTestPlan: preferredTestPlan)
            .map(TestProductReference.xctestrun)
    }

    func missingTestProductReferenceMessage(paths: ExecutionPaths, context: ToolExecutionContext) -> String {
        if context.profile.testProducts.useForTesting {
            return "No .xctestproducts bundle was generated at \(paths.testProducts.path)"
        }
        return "No .xctestrun file was generated under \(paths.derivedData.appendingPathComponent("Build/Products").path)"
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

    func parseCreatedSimulatorID(from output: String) -> String? {
        simulatorLifecycle.parseCreatedSimulatorID(from: output)
    }

    private func classifyUnhandled(_ error: Error) -> ResultClass {
        let description = String(describing: error)
        let runnerPatterns = [
            "Unable to boot simulator",
            "Unable to confirm simulator boot status",
            "Unable to list simulators",
            "Unable to create managed simulator",
            "Unable to clone managed simulator",
            "Unable to configure simulator privacy",
            "Unable to resolve executable",
            "already leased by another XCSteward job",
            "Competing simulator-hosted test activity",
            "Unable to enumerate tests",
        ]
        return runnerPatterns.contains { description.contains($0) }
            ? .runnerBootstrapFailure
            : .internalError
    }
}
