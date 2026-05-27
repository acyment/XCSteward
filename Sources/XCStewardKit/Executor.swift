// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Darwin
import Foundation

final class JobExecutor: @unchecked Sendable {
    private let environment: AppEnvironment
    private let resultReporter: ResultReporter
    private let commandRecordLock = NSLock()
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

    private func acquireSimulatorLease(simulatorID: String, job: JobRecord, store: StateStore) throws {
        let deadline = Date().addingTimeInterval(simulatorLeaseWaitTimeout())
        while true {
            if try store.acquireSimulatorLease(simulatorID: simulatorID, jobID: job.id, pid: getpid()) {
                return
            }
            guard let lease = try store.simulatorLease(simulatorID: simulatorID) else {
                continue
            }
            guard try shouldWaitForSimulatorLease(lease, store: store) else {
                throw XCStewardError.commandFailed("Simulator \(simulatorID) is already leased by another XCSteward job")
            }
            if Date() >= deadline {
                throw XCStewardError.commandFailed(
                    "Timed out waiting for simulator \(simulatorID) lease held by XCSteward job \(lease.jobID)"
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func shouldWaitForSimulatorLease(_ lease: SimulatorLease, store: StateStore) throws -> Bool {
        guard let holder = try store.fetchJob(id: lease.jobID) else {
            return false
        }
        return holder.state == .running
    }

    private func simulatorLeaseWaitTimeout() -> TimeInterval {
        guard let rawValue = environment.processInfo.environment["XCSTEWARD_SIMULATOR_LEASE_WAIT_SECONDS"],
              let value = Double(rawValue),
              value >= 0 else {
            return 60
        }
        return value
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
            let toolContext = ToolExecutionContext(
                profile: profile,
                jobID: job.id,
                store: store,
                commandLog: paths.commandLog,
                commandEventLog: paths.commandEventLog
            )
            let heartbeat = JobLeaseHeartbeat(environment: environment, jobID: job.id)
            heartbeat.start()
            defer { heartbeat.stop() }

            try validateProfileRoot(profile)
            try validateXcodebuildAvailable(context: toolContext)
            if try isMacOSOnlyDestination(profile: profile, context: toolContext) {
                let message = "Native macOS app destinations are outside XCSteward public-alpha support; run direct xcodebuild -destination platform=macOS until XCSteward adds a simulator-free destination path."
                try warnAndLog(message: message, logURL: paths.buildLog, combinedLog: paths.combinedLog)
                return try finish(
                    job: job,
                    profile: profile,
                    paths: paths,
                    state: .failed,
                    resultClass: .unsupportedDestination,
                    exitCode: nil,
                    startedAt: jobStart,
                    simulatorID: "",
                    artifacts: paths.artifacts(fileSystem: environment.fileSystem),
                    summaryLine: message,
                    includeToolProbes: false
                )
            }
            let resolvedSimulatorID = try resolveSimulatorID(request: job.request, context: toolContext)
            simulatorID = resolvedSimulatorID
            try store.updateJob(id: job.id, patch: JobStatePatch(state: .running, simulatorID: resolvedSimulatorID))
            try acquireSimulatorLease(simulatorID: resolvedSimulatorID, job: job, store: store)
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
            if buildResult.timedOut {
                return try finish(
                    job: job,
                    profile: profile,
                    paths: paths,
                    state: .failed,
                    resultClass: .buildTimeout,
                    exitCode: buildResult.exitCode,
                    startedAt: jobStart,
                    simulatorID: resolvedSimulatorID,
                    artifacts: paths.initialArtifacts
                )
            }
            if buildResult.exitCode != 0 {
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
            if testOutcome.resultClass != .canceled, try isCancelRequested(context: toolContext) {
                return try finishCanceled(
                    job: job,
                    profile: profile,
                    paths: paths,
                    exitCode: testOutcome.exitCode,
                    startedAt: jobStart,
                    simulatorID: resolvedSimulatorID,
                    artifacts: paths.artifacts(fileSystem: environment.fileSystem)
                )
            }
            let summaryProbe = resultReporter.parseXCResultSummaryProbe(at: paths.resultBundle, context: toolContext)
            let parsedSummary = summaryProbe.summary
            if testOutcome.resultClass != .canceled, try isCancelRequested(context: toolContext) {
                return try finishCanceled(
                    job: job,
                    profile: profile,
                    paths: paths,
                    exitCode: testOutcome.exitCode,
                    startedAt: jobStart,
                    simulatorID: resolvedSimulatorID,
                    artifacts: paths.artifacts(fileSystem: environment.fileSystem)
                )
            }
            let resultClass = testOutcome.resultClass == .success && summaryProbe.failsSuccessfulTestRun
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
            var finalResultClass = resultClass
            do {
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
            } catch {
                _ = try? failAndLog(
                    message: "Unable to write JUnit report: \(error)",
                    exitCode: 75,
                    logURL: paths.testLog,
                    combinedLog: paths.combinedLog
                )
                if finalResultClass == .success {
                    finalResultClass = .artifactFailure
                    _ = captureSimulatorDiagnostics(
                        simulatorID: resolvedSimulatorID,
                        outputURL: paths.simulatorDiagnostics,
                        context: toolContext
                    )
                }
            }
            let artifacts = paths.artifacts(fileSystem: environment.fileSystem)
            return try finish(
                job: job,
                profile: profile,
                paths: paths,
                state: resultPolicy.terminalState(for: finalResultClass),
                resultClass: finalResultClass,
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
            if resultClass.isInfrastructureFailure, !isInvalidConfiguration(error) {
                let failureContext = ToolExecutionContext(
                    profile: profile,
                    jobID: job.id,
                    store: store,
                    commandLog: paths.commandLog,
                    commandEventLog: paths.commandEventLog
                )
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
                summaryLine: String(describing: error),
                includeToolProbes: !isInvalidConfiguration(error)
            )
        }
    }

    private func validateProfileRoot(_ profile: ProjectProfile) throws {
        let repoURL = URL(fileURLWithPath: profile.repoRoot)
        if !environment.fileSystem.fileExists(repoURL) || environment.fileSystem.isRegularFile(repoURL) {
            throw XCStewardError.invalidConfiguration(
                "Profile \(profile.name) repo_root is not an accessible directory: \(profile.repoRoot)"
            )
        }
    }

    private func validateXcodebuildAvailable(context: ToolExecutionContext) throws {
        let result = try runTool(
            tool: "xcrun",
            arguments: ["--find", "xcodebuild"],
            timeout: 5,
            context: context
        )
        try throwIfCanceled(result, context: context)
        guard result.exitCode == 0, !result.timedOut else {
            throw commandFailed("Unable to resolve xcodebuild with xcrun --find xcodebuild", output: result.output)
        }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw commandFailed("Unable to resolve xcodebuild with xcrun --find xcodebuild", output: "xcrun returned an empty path")
        }
    }

    private func isMacOSOnlyDestination(profile: ProjectProfile, context: ToolExecutionContext) throws -> Bool {
        let result = try runTool(
            tool: "xcodebuild",
            arguments: XcodebuildCommandBuilder(profile: profile).showDestinations(),
            timeout: profile.destination.timeout.map(TimeInterval.init) ?? 30,
            context: context
        )
        try throwIfCanceled(result, context: context)
        guard result.exitCode == 0, !result.timedOut else {
            throw commandFailed("Unable to inspect runnable destinations for the configured scheme", output: result.output)
        }
        return !DoctorOutputParsers.showDestinationsOutputExposesIOSSimulator(result.output) &&
            !DoctorOutputParsers.showDestinationsOutputExposesOnlyIOSSimulatorPlaceholder(result.output) &&
            DoctorOutputParsers.showDestinationsOutputExposesMacOSDestination(result.output)
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
            let firstOutcome = classify(run: run, resultBundle: paths.resultBundle)
            try recordRetryAttemptEvidence(
                fileSystem: environment.fileSystem,
                sourceResultBundle: paths.resultBundle,
                sourceResultStream: paths.resultStream,
                attemptPaths: paths.testAttemptPaths(attempt: 1),
                attempt: 1,
                phase: "test",
                outcome: firstOutcome,
                run: run
            ) {
                captureSimulatorDiagnostics(
                    simulatorID: simulatorID,
                    outputURL: paths.simulatorDiagnostics,
                    context: context
                )
            }
            try? context.store.recordInfrastructureEvent(
                jobID: context.jobID,
                simulatorID: simulatorID,
                resultClass: .runnerBootstrapFailure,
                message: "Retrying xcode-managed test after runner bootstrap failure"
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
        let arguments = XcodebuildCommandBuilder(profile: profile).xcodeManagedTest(
            testReference: testReference,
            simulatorID: simulatorID,
            paths: paths,
            request: request
        )
        return try runXcodebuildTestAttempt(
            XcodebuildTestAttempt(
                arguments: arguments,
                simulatorID: simulatorID,
                resultStream: paths.resultStream,
                logURL: paths.testLog,
                combinedLog: paths.combinedLog,
                temporaryDirectory: paths.temporaryRoot.appendingPathComponent("test"),
                phase: "test",
                shardID: nil,
                shardIndex: nil,
                totalShards: nil
            ),
            context: context
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
        try runAndLog(
            tool: tool,
            arguments: arguments,
            timeout: timeout,
            logURL: logURL,
            combinedLog: combinedLog,
            context: context,
            environmentOverrides: environmentOverrides,
            processStarted: nil
        )
    }

    func runAndLog(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext,
        environmentOverrides: [String: String],
        processStarted: ((Int32) throws -> Void)?
    ) throws -> ToolResult {
        try appendCommandStartMarker(
            tool: tool,
            arguments: arguments,
            timeout: timeout,
            context: context,
            environmentOverrides: environmentOverrides,
            logURL: logURL,
            combinedLog: combinedLog
        )
        let result = try runTool(
            tool: tool,
            arguments: arguments,
            timeout: timeout,
            context: context,
            environmentOverrides: environmentOverrides,
            processStarted: processStarted
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
        try runTool(
            tool: tool,
            arguments: arguments,
            timeout: timeout,
            context: context,
            environmentOverrides: environmentOverrides,
            processStarted: nil
        )
    }

    func runTool(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        environmentOverrides: [String: String],
        processStarted: ((Int32) throws -> Void)?
    ) throws -> ToolResult {
        if let tmpdir = environmentOverrides["TMPDIR"], !tmpdir.isEmpty {
            try? environment.fileSystem.createDirectory(URL(fileURLWithPath: tmpdir))
        }
        var activePID: Int32?
        recordCommandEvent(
            event: "launching",
            tool: tool,
            arguments: arguments,
            timeout: timeout,
            context: context,
            environmentOverrides: environmentOverrides,
            pid: nil,
            result: nil,
            error: nil
        )
        defer {
            if let activePID {
                try? context.store.clearJobProcessID(id: context.jobID, processID: activePID)
            } else {
                try? context.store.clearJobProcessID(id: context.jobID)
            }
        }
        let toolEnvironment = context.profile.env.merging(environmentOverrides) { _, override in override }
        do {
            let result = try environment.toolRunner.run(
                tool: tool,
                arguments: arguments,
                environment: toolEnvironment,
                workingDirectory: context.profile.workingDirectory,
                timeout: timeout,
                processStarted: { pid in
                    activePID = pid
                    self.recordCommandEvent(
                        event: "started",
                        tool: tool,
                        arguments: arguments,
                        timeout: timeout,
                        context: context,
                        environmentOverrides: environmentOverrides,
                        pid: pid,
                        result: nil,
                        error: nil
                    )
                    try processStarted?(pid)
                    try context.store.updateJob(id: context.jobID, patch: JobStatePatch(state: .running, processID: pid))
                },
                shouldTerminate: {
                    try context.store.fetchJob(id: context.jobID)?.cancelRequested == true
                }
            )
            recordCommandEvent(
                event: "finished",
                tool: tool,
                arguments: arguments,
                timeout: timeout,
                context: context,
                environmentOverrides: environmentOverrides,
                pid: activePID,
                result: result,
                error: nil
            )
            recordCommand(
                tool: tool,
                arguments: arguments,
                timeout: timeout,
                context: context,
                environmentOverrides: environmentOverrides,
                result: result,
                error: nil
            )
            return result
        } catch {
            recordCommandEvent(
                event: "failed",
                tool: tool,
                arguments: arguments,
                timeout: timeout,
                context: context,
                environmentOverrides: environmentOverrides,
                pid: activePID,
                result: nil,
                error: error
            )
            recordCommand(
                tool: tool,
                arguments: arguments,
                timeout: timeout,
                context: context,
                environmentOverrides: environmentOverrides,
                result: nil,
                error: error
            )
            throw error
        }
    }

    private func appendCommandStartMarker(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        environmentOverrides: [String: String],
        logURL: URL,
        combinedLog: URL
    ) throws {
        let phase = commandPhase(environmentOverrides: environmentOverrides)
        let phasePrefix = phase.map { "\($0) " } ?? ""
        let eventLogLine = context.commandEventLog.map { "\nXCSteward command events: \($0.path)" } ?? ""
        let line = """
        XCSteward starting \(phasePrefix)command: \(commandLine(tool: tool, arguments: arguments))
        XCSteward command timeout: \(formattedTimeout(timeout))\(eventLogLine)

        """
        let data = Data(line.utf8)
        try environment.fileSystem.appendData(data, to: logURL)
        try environment.fileSystem.appendData(data, to: combinedLog)
    }

    private func recordCommand(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        environmentOverrides: [String: String],
        result: ToolResult?,
        error: Error?
    ) {
        guard let commandLog = context.commandLog else {
            return
        }
        let record = RunCommandRecord(
            tool: tool,
            arguments: arguments,
            commandLine: commandLine(tool: tool, arguments: arguments),
            workingDirectory: context.profile.workingDirectory.path,
            timeoutSeconds: timeout,
            phase: commandPhase(environmentOverrides: environmentOverrides),
            exitCode: result?.exitCode,
            timedOut: result?.timedOut ?? false,
            error: error.map { String(describing: $0) }
        )
        appendJSONLine(record, to: commandLog)
    }

    private func recordCommandEvent(
        event: String,
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        environmentOverrides: [String: String],
        pid: Int32?,
        result: ToolResult?,
        error: Error?
    ) {
        guard let commandEventLog = context.commandEventLog else {
            return
        }
        let record = RunCommandEvent(
            event: event,
            timestamp: environment.clock.now().timeIntervalSince1970,
            tool: tool,
            arguments: arguments,
            commandLine: commandLine(tool: tool, arguments: arguments),
            workingDirectory: context.profile.workingDirectory.path,
            timeoutSeconds: timeout,
            phase: commandPhase(environmentOverrides: environmentOverrides),
            pid: pid,
            exitCode: result?.exitCode,
            timedOut: result?.timedOut,
            error: error.map { String(describing: $0) }
        )
        appendJSONLine(record, to: commandEventLog)
    }

    private func appendJSONLine<T: Encodable>(_ record: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(record) else {
            return
        }
        data.append(contentsOf: "\n".utf8)
        commandRecordLock.lock()
        defer { commandRecordLock.unlock() }
        try? environment.fileSystem.appendData(data, to: url)
    }

    private func commandLine(tool: String, arguments: [String]) -> String {
        ([tool] + arguments).joined(separator: " ")
    }

    private func commandPhase(environmentOverrides: [String: String]) -> String? {
        environmentOverrides["XCSTEWARD_PHASE"] ?? environmentOverrides["TEST_RUNNER_XCSTEWARD_PHASE"]
    }

    private func formattedTimeout(_ timeout: TimeInterval) -> String {
        if timeout.rounded() == timeout {
            return "\(Int(timeout))s"
        }
        return String(format: "%.3fs", timeout)
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
        summaryLine: String? = nil,
        includeToolProbes: Bool = true
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
            paths: paths,
            includeToolProbes: includeToolProbes
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
        if case XCStewardError.invalidConfiguration = error {
            return .runnerBootstrapFailure
        }
        let description = String(describing: error)
        let runnerPatterns = [
            "Unable to boot simulator",
            "Unable to confirm simulator boot status",
            "Unable to list simulators",
            "Unable to parse simulator list",
            "Configured simulator",
            "Requested simulator override",
            "Unable to create managed simulator",
            "Unable to clone managed simulator",
            "Unable to configure simulator privacy",
            "Unable to resolve xcodebuild",
            "Unable to resolve executable",
            "already leased by another XCSteward job",
            "Competing simulator-hosted test activity",
            "Unable to enumerate tests",
        ]
        return runnerPatterns.contains { description.contains($0) }
            ? .runnerBootstrapFailure
            : .internalError
    }

    private func isInvalidConfiguration(_ error: Error) -> Bool {
        if case XCStewardError.invalidConfiguration = error {
            return true
        }
        return false
    }
}
