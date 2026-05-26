import Darwin
import Dispatch
import Foundation

private struct ManualShardExecutionResult: Sendable {
    var report: ShardReport
    var outcome: TestOutcome
    var parsedSummary: XCResultSummary?
    var timingSamples: [TestTimingSample]
}

private final class ManualShardRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ManualShardExecutionResult] = []
    private var firstError: Error?
    private var stopLaunching = false
    private var activeProcessIDs: Set<Int32> = []

    func append(_ result: ManualShardExecutionResult) {
        lock.lock()
        results.append(result)
        lock.unlock()
    }

    func record(error: Error) -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        if firstError == nil {
            firstError = error
        }
        stopLaunching = true
        return Array(activeProcessIDs)
    }

    func requestStopForFatalShardResult(_ result: ManualShardExecutionResult) -> [Int32] {
        requestStopForFatalResultClass(result.outcome.resultClass)
    }

    func requestStopForFatalResultClass(_ resultClass: ResultClass) -> [Int32] {
        guard resultClass.isManualShardFatal else {
            return []
        }
        lock.lock()
        defer { lock.unlock() }
        stopLaunching = true
        return Array(activeProcessIDs)
    }

    func shouldStopLaunching() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopLaunching
    }

    func recordActiveProcess(_ pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        activeProcessIDs.insert(pid)
        return stopLaunching
    }

    func clearActiveProcess(_ pid: Int32) {
        lock.lock()
        activeProcessIDs.remove(pid)
        lock.unlock()
    }

    func snapshot() -> (results: [ManualShardExecutionResult], error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (results, firstError)
    }
}

private extension ResultClass {
    var isManualShardFatal: Bool {
        switch self {
        case .runnerBootstrapFailure, .unsupportedDestination, .artifactFailure, .internalError:
            return true
        case .success, .buildFailure, .buildTimeout, .testFailure, .testTimeout, .canceled:
            return false
        }
    }
}

final class ManualShardRunner: @unchecked Sendable {
    private let environment: AppEnvironment
    private let runtime: ManualShardRuntime
    private let resultReporter: ResultReporter
    private let planner = ManualShardPlanner()

    init(environment: AppEnvironment, runtime: ManualShardRuntime, resultReporter: ResultReporter) {
        self.environment = environment
        self.runtime = runtime
        self.resultReporter = resultReporter
    }

    func run(
        primarySimulatorID: String,
        paths: ExecutionPaths,
        request: JobRequest,
        context: ToolExecutionContext
    ) throws -> ManualRunResult {
        let manualRunStartedAt = environment.clock.now().timeIntervalSince1970
        let profile = context.profile
        guard let testReference = runtime.resolveTestProductReference(
            in: paths,
            preferredTestPlan: request.testPlan ?? profile.defaultTestPlan,
            context: context
        ) else {
            let result = try runtime.failAndLog(
                message: runtime.missingTestProductReferenceMessage(paths: paths, context: context),
                exitCode: 70,
                logURL: paths.testLog,
                combinedLog: paths.combinedLog
            )
            return ManualRunResult(
                resultClass: .runnerBootstrapFailure,
                exitCode: result.exitCode,
                counts: nil,
                artifacts: paths.initialArtifacts,
                shardReports: [],
                successSummaryLine: nil
            )
        }

        let testIdentifiers = try manualShardTestIdentifiers(
            request: request,
            testReference: testReference,
            simulatorID: primarySimulatorID,
            paths: paths,
            context: context
        )
        guard !testIdentifiers.isEmpty else {
            let result = try runtime.failAndLog(
                message: "Manual sharding found no tests to run",
                exitCode: 70,
                logURL: paths.testLog,
                combinedLog: paths.combinedLog
            )
            return ManualRunResult(
                resultClass: .runnerBootstrapFailure,
                exitCode: result.exitCode,
                counts: nil,
                artifacts: paths.initialArtifacts,
                shardReports: [],
                successSummaryLine: nil
            )
        }

        let timingEstimates = try context.store.testTimingEstimates(project: profile.name, identifiers: testIdentifiers)
        let shardGroups = planner.splitTestIdentifiers(
            testIdentifiers,
            shardCount: min(profile.parallel.shardCount, testIdentifiers.count),
            timingEstimates: timingEstimates
        )
        let simulatorSelection = try manualShardSimulatorIDs(
            request: request,
            primarySimulatorID: primarySimulatorID,
            requiredCount: shardGroups.count,
            context: context
        )
        let simulatorIDs = simulatorSelection.simulatorIDs
        let transientSimulatorIDs = Set(simulatorSelection.transientSimulatorIDs)
        var additionalLeases: [String] = []
        do {
            for simulatorID in simulatorIDs.dropFirst() {
                guard try context.store.acquireSimulatorLease(simulatorID: simulatorID, jobID: context.jobID, pid: getpid()) else {
                    throw XCStewardError.commandFailed("Simulator \(simulatorID) is already leased by another XCSteward job")
                }
                additionalLeases.append(simulatorID)
            }
        } catch {
            cleanupTransientSimulators(simulatorSelection.transientSimulatorIDs, context: context)
            throw error
        }
        defer {
            for simulatorID in additionalLeases {
                try? context.store.releaseSimulatorLease(simulatorID: simulatorID, jobID: context.jobID)
            }
        }
        defer {
            for simulatorID in additionalLeases {
                if transientSimulatorIDs.contains(simulatorID) {
                    deleteTransientSimulatorAfterJob(simulatorID: simulatorID, context: context)
                } else {
                    runtime.cleanupSimulatorAfterJob(simulatorID: simulatorID, context: context)
                }
            }
        }

        if simulatorSelection.primaryNeedsBoot {
            try runtime.bootSimulator(simulatorID: primarySimulatorID, context: context)
        }
        for simulatorID in simulatorIDs.dropFirst() {
            try runtime.bootSimulator(simulatorID: simulatorID, context: context)
        }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "XCSteward.ManualShardRunner.shards", attributes: .concurrent)
        let state = ManualShardRunState()
        let jobID = context.jobID
        let commandLog = context.commandLog
        for (index, identifiers) in shardGroups.enumerated() {
            let shardPaths = paths.shardPaths(index: index)
            let simulatorID = simulatorIDs[index]
            group.enter()
            queue.async {
                defer { group.leave() }
                guard !state.shouldStopLaunching() else {
                    return
                }
                do {
                    let shardContext = ToolExecutionContext(
                        profile: profile,
                        jobID: jobID,
                        store: try StateStore(environment: self.environment),
                        commandLog: commandLog
                    )
                    let result = try self.runManualShard(
                        testReference: testReference,
                        simulatorID: simulatorID,
                        onlyTesting: identifiers,
                        skipTesting: request.skipTesting,
                        onlyTestConfigurations: request.onlyTestConfigurations,
                        skipTestConfigurations: request.skipTestConfigurations,
                        shardIndex: index,
                        totalShards: shardGroups.count,
                        shardPaths: shardPaths,
                        combinedLog: paths.combinedLog,
                        context: shardContext,
                        state: state
                    )
                    state.append(result)
                    if result.outcome.resultClass.isManualShardFatal {
                        self.terminateManualShardProcesses(
                            state.requestStopForFatalShardResult(result),
                            context: shardContext
                        )
                    }
                } catch {
                    self.terminateManualShardProcesses(
                        state.record(error: error),
                        jobID: jobID,
                        stateRoot: self.environment.paths.stateRoot.path
                    )
                }
            }
        }
        group.wait()

        let (results, error) = state.snapshot()
        if let error {
            throw error
        }
        let sorted = results.sorted { $0.report.shardID < $1.report.shardID }
        let reports = sorted.map(\.report)
        let resultClass = planner.aggregateResultClass(sorted.map(\.outcome.resultClass))
        let timingSamples = sorted
            .filter { $0.outcome.resultClass != .runnerBootstrapFailure && $0.outcome.resultClass != .artifactFailure }
            .flatMap(\.timingSamples)
        if !timingSamples.isEmpty {
            try? context.store.recordTestTimings(project: profile.name, samples: timingSamples)
        }
        if resultClass != .canceled {
            try? context.store.updateJob(id: context.jobID, patch: JobStatePatch(cancelRequested: false))
        }
        let counts = resultReporter.aggregateCounts(sorted.compactMap(\.parsedSummary))
        try environment.fileSystem.writeData(try jsonData(reports), to: paths.shardsManifest)
        if resultClass == .success {
            try mergeShardResultBundles(reports, paths: paths, context: context)
        }
        try resultReporter.writeManualRunDiagnostics(
            resultClass: resultClass,
            counts: counts,
            reports: reports,
            paths: paths,
            context: context
        )
        try resultReporter.writeJUnitReport(
            project: profile.name,
            resultClass: resultClass,
            counts: counts,
            durationSeconds: environment.clock.now().timeIntervalSince1970 - manualRunStartedAt,
            cases: resultReporter.junitCasesForShardReports(reports),
            outputURL: paths.junitReport
        )
        return ManualRunResult(
            resultClass: resultClass,
            exitCode: sorted.compactMap(\.outcome.exitCode).first { $0 != 0 } ?? 0,
            counts: counts,
            artifacts: paths.manualShardArtifacts(fileSystem: environment.fileSystem),
            shardReports: reports,
            successSummaryLine: resultClass == .success
                ? shardSuccessSummary(for: profile.parallel.mode, count: reports.count)
                : nil
        )
    }

    private func terminateManualShardProcesses(_ processIDs: [Int32], context: ToolExecutionContext) {
        terminateManualShardProcesses(processIDs, jobID: context.jobID, store: context.store)
    }

    private func terminateManualShardProcesses(_ processIDs: [Int32], jobID: String, stateRoot: String) {
        guard let store = try? StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: URL(fileURLWithPath: stateRoot)))) else {
            signalManualShardProcesses(Set(processIDs))
            return
        }
        terminateManualShardProcesses(processIDs, jobID: jobID, store: store)
    }

    private func terminateManualShardProcesses(_ processIDs: [Int32], jobID: String, store: StateStore) {
        try? store.requestCancel(jobID: jobID)
        var processIDs = Set(processIDs)
        if let activeProcessID = try? store.fetchJob(id: jobID)?.processID {
            processIDs.insert(activeProcessID)
        }
        signalManualShardProcesses(processIDs)
    }

    private func signalManualShardProcesses(_ processIDs: Set<Int32>) {
        for pid in processIDs where pid > 0 {
            _ = kill(-pid, SIGTERM)
            _ = kill(pid, SIGTERM)
        }
    }

    private func mergeShardResultBundles(_ reports: [ShardReport], paths: ExecutionPaths, context: ToolExecutionContext) throws {
        let resultBundles = reports.map { URL(fileURLWithPath: $0.resultBundle) }
        guard resultBundles.count > 1, resultBundles.allSatisfy(environment.fileSystem.fileExists) else {
            return
        }
        if environment.fileSystem.fileExists(paths.mergedResultBundle) {
            try environment.fileSystem.removeItem(paths.mergedResultBundle)
        }
        let arguments = ["xcresulttool", "merge"] + resultBundles.map(\.path) + ["--output-path", paths.mergedResultBundle.path]
        let merge = try runtime.runTool(
            tool: "xcrun",
            arguments: arguments,
            timeout: context.profile.timeouts.test,
            context: context
        )
        if merge.exitCode != 0 || merge.timedOut || !environment.fileSystem.fileExists(paths.mergedResultBundle) {
            try runtime.warnAndLog(
                message: "Unable to merge shard result bundles; preserving per-shard .xcresult bundles",
                logURL: paths.testLog,
                combinedLog: paths.combinedLog
            )
        }
    }

    private func runManualShard(
        testReference: TestProductReference,
        simulatorID: String,
        onlyTesting: [String],
        skipTesting: [String],
        onlyTestConfigurations: [String],
        skipTestConfigurations: [String],
        shardIndex: Int,
        totalShards: Int,
        shardPaths: ShardPaths,
        combinedLog: URL,
        context: ToolExecutionContext,
        state: ManualShardRunState
    ) throws -> ManualShardExecutionResult {
        try environment.fileSystem.createDirectory(shardPaths.root)
        if environment.fileSystem.fileExists(shardPaths.resultBundle) {
            try environment.fileSystem.removeItem(shardPaths.resultBundle)
        }
        var attempts = 1
        var retryReason: String?
        var simulatorDiagnostics: [String] = []
        var attemptArtifacts: [AttemptArtifact] = []
        var run = try runManualShardAttempt(
            testReference: testReference,
            simulatorID: simulatorID,
            onlyTesting: onlyTesting,
            skipTesting: skipTesting,
            onlyTestConfigurations: onlyTestConfigurations,
            skipTestConfigurations: skipTestConfigurations,
            shardIndex: shardIndex,
            totalShards: totalShards,
            shardPaths: shardPaths,
            combinedLog: combinedLog,
            context: context,
            state: state
        )
        var outcome = runtime.classify(run: run, resultBundle: shardPaths.resultBundle)
        if shouldRetryManualShardFailure(outcome: outcome, run: run) {
            let retryEvidence = try recordRetryAttemptEvidence(
                fileSystem: environment.fileSystem,
                sourceResultBundle: shardPaths.resultBundle,
                sourceResultStream: shardPaths.resultStream,
                attemptPaths: shardPaths.attemptPaths(attempt: attempts),
                attempt: attempts,
                phase: "manual-shard",
                outcome: outcome,
                run: run
            ) {
                runtime.captureSimulatorDiagnostics(
                    simulatorID: simulatorID,
                    outputURL: shardPaths.simulatorDiagnostics(attempt: attempts),
                    context: context
                )
            }
            retryReason = retryEvidence.retryReason
            attemptArtifacts.append(retryEvidence.artifact)
            if let diagnostic = retryEvidence.simulatorDiagnostic {
                simulatorDiagnostics.append(diagnostic)
            }
            attempts = 2
            try? context.store.recordInfrastructureEvent(
                jobID: context.jobID,
                simulatorID: simulatorID,
                resultClass: outcome.resultClass,
                message: "Retrying \(shardPaths.id) after \(outcome.resultClass.rawValue)"
            )
            try runtime.warnAndLog(
                message: "Retrying \(shardPaths.id) on simulator \(simulatorID) after \(outcome.resultClass.rawValue)",
                logURL: shardPaths.testLog,
                combinedLog: combinedLog
            )
            try recoverSimulatorForShardRetry(simulatorID: simulatorID, context: context)
            if environment.fileSystem.fileExists(shardPaths.resultBundle) {
                try environment.fileSystem.removeItem(shardPaths.resultBundle)
            }
            run = try runManualShardAttempt(
                testReference: testReference,
                simulatorID: simulatorID,
                onlyTesting: onlyTesting,
                skipTesting: skipTesting,
                onlyTestConfigurations: onlyTestConfigurations,
                skipTestConfigurations: skipTestConfigurations,
                shardIndex: shardIndex,
                totalShards: totalShards,
                shardPaths: shardPaths,
                combinedLog: combinedLog,
                context: context,
                state: state
            )
            outcome = runtime.classify(run: run, resultBundle: shardPaths.resultBundle)
            if outcome.resultClass.isInfrastructureFailure,
               let diagnostic = runtime.captureSimulatorDiagnostics(
                   simulatorID: simulatorID,
                   outputURL: shardPaths.simulatorDiagnostics(attempt: attempts),
                   context: context
               ) {
                simulatorDiagnostics.append(diagnostic)
            }
        }
        if outcome.resultClass.isManualShardFatal {
            let fatalProcessIDs = state.requestStopForFatalResultClass(outcome.resultClass)
            try? runtime.warnAndLog(
                message: "Stopping manual shard peers after \(shardPaths.id) produced \(outcome.resultClass.rawValue)",
                logURL: shardPaths.testLog,
                combinedLog: combinedLog
            )
            try? context.store.recordInfrastructureEvent(
                jobID: context.jobID,
                simulatorID: simulatorID,
                resultClass: outcome.resultClass,
                message: "Stopping manual shard peers after \(shardPaths.id) produced \(outcome.resultClass.rawValue)"
            )
            self.terminateManualShardProcesses(fatalProcessIDs, context: context)
        }
        let parsedSummary = resultReporter.parseXCResultSummary(at: shardPaths.resultBundle)
        let timingSamples = resultReporter.parseXCResultTestTimings(at: shardPaths.resultBundle)
        return ManualShardExecutionResult(
            report: ShardReport(
                shardID: shardPaths.id,
                simulatorID: simulatorID,
                onlyTesting: onlyTesting,
                resultBundle: shardPaths.resultBundle.path,
                resultStream: environment.fileSystem.fileExists(shardPaths.resultStream) ? shardPaths.resultStream.path : nil,
                log: shardPaths.testLog.path,
                resultClass: outcome.resultClass,
                exitCode: outcome.exitCode,
                counts: resultReporter.counts(from: parsedSummary),
                attempts: attempts,
                retryReason: retryReason,
                simulatorDiagnostics: simulatorDiagnostics,
                attemptArtifacts: attemptArtifacts
            ),
            outcome: outcome,
            parsedSummary: parsedSummary,
            timingSamples: timingSamples
        )
    }

    private func runManualShardAttempt(
        testReference: TestProductReference,
        simulatorID: String,
        onlyTesting: [String],
        skipTesting: [String],
        onlyTestConfigurations: [String],
        skipTestConfigurations: [String],
        shardIndex: Int,
        totalShards: Int,
        shardPaths: ShardPaths,
        combinedLog: URL,
        context: ToolExecutionContext,
        state: ManualShardRunState
    ) throws -> ToolResult {
        let arguments = XcodebuildCommandBuilder(profile: context.profile).manualShardTest(
            testReference: testReference,
            simulatorID: simulatorID,
            resultBundle: shardPaths.resultBundle,
            resultStream: shardPaths.resultStream,
            onlyTesting: onlyTesting,
            skipTesting: skipTesting,
            onlyTestConfigurations: onlyTestConfigurations,
            skipTestConfigurations: skipTestConfigurations
        )
        var activePID: Int32?
        defer {
            if let activePID {
                state.clearActiveProcess(activePID)
            }
        }
        return try runtime.runXcodebuildTestAttempt(
            XcodebuildTestAttempt(
                arguments: arguments,
                simulatorID: simulatorID,
                resultStream: shardPaths.resultStream,
                logURL: shardPaths.testLog,
                combinedLog: combinedLog,
                temporaryDirectory: shardPaths.temporaryDirectory,
                phase: "manual-shard",
                shardID: shardPaths.id,
                shardIndex: shardIndex,
                totalShards: totalShards
            ),
            context: context,
            processStarted: { pid in
                activePID = pid
                if state.recordActiveProcess(pid) {
                    self.signalManualShardProcesses([pid])
                }
            }
        )
    }

    private func enumerateTests(
        testReference: TestProductReference,
        simulatorID: String,
        request: JobRequest,
        paths: ExecutionPaths,
        context: ToolExecutionContext
    ) throws -> [String] {
        if environment.fileSystem.fileExists(paths.testEnumeration) {
            try environment.fileSystem.removeItem(paths.testEnumeration)
        }
        let arguments = XcodebuildCommandBuilder(profile: context.profile).enumerateTests(
            testReference: testReference,
            simulatorID: simulatorID,
            outputPath: paths.testEnumeration,
            onlyTestConfigurations: request.onlyTestConfigurations,
            skipTestConfigurations: request.skipTestConfigurations
        )
        let run = try runtime.runAndLog(
            tool: "xcodebuild",
            arguments: arguments,
            timeout: context.profile.timeouts.test,
            logURL: paths.testLog,
            combinedLog: paths.combinedLog,
            context: context,
            environmentOverrides: runtime.testRunnerEnvironment(
                context: context,
                temporaryDirectory: paths.temporaryRoot.appendingPathComponent("enumerate-tests"),
                phase: "enumerate-tests",
                shardID: nil,
                shardIndex: nil,
                totalShards: nil
            )
        )
        try runtime.throwIfCanceled(run, context: context)
        guard run.exitCode == 0, !run.timedOut else {
            throw runtime.commandFailed("Unable to enumerate tests for manual sharding", output: run.output)
        }
        let data: Data
        if environment.fileSystem.fileExists(paths.testEnumeration) {
            data = try environment.fileSystem.readData(from: paths.testEnumeration)
        } else if let outputData = run.output.data(using: String.Encoding.utf8) {
            data = outputData
        } else {
            return []
        }
        return try planner.parseEnumeratedTestIdentifiers(from: data)
    }

    private func manualShardTestIdentifiers(
        request: JobRequest,
        testReference: TestProductReference,
        simulatorID: String,
        paths: ExecutionPaths,
        context: ToolExecutionContext
    ) throws -> [String] {
        if !request.onlyTesting.isEmpty {
            return request.onlyTesting
        }
        let enumerated = try enumerateTests(
            testReference: testReference,
            simulatorID: simulatorID,
            request: request,
            paths: paths,
            context: context
        )
        return planner.filterEnumeratedTestIdentifiers(
            enumerated,
            skipTesting: request.skipTesting
        ) { identifier, skip in
            runtime.testIdentifier(identifier, matchesSkipFilter: skip)
        }
    }

    private func manualShardSimulatorIDs(
        request: JobRequest,
        primarySimulatorID: String,
        requiredCount: Int,
        context: ToolExecutionContext
    ) throws -> ManualShardSimulatorSelection {
        let plan = planner.simulatorPlan(
            primarySimulatorID: primarySimulatorID,
            requestedSimulatorID: request.simulatorID,
            defaultSimulatorID: context.profile.defaultSimulatorID,
            allowedSimulatorIDs: context.profile.allowedSimulatorIDs,
            requiredCount: requiredCount
        )
        if let selection = planner.configuredSimulatorSelection(from: plan) {
            return selection
        }
        guard let managed = context.profile.managedSimulator, managed.cloneForShards else {
            throw XCStewardError.invalidConfiguration(
                "Profile \(context.profile.name) manual-shards requires \(requiredCount) simulator IDs but only \(plan.configuredSimulatorIDs.count) configured"
            )
        }

        var simulatorIDs = plan.configuredSimulatorIDs
        var transientSimulatorIDs: [String] = []
        do {
            try shutdownSimulatorForCloneTemplate(simulatorID: primarySimulatorID, context: context)
            while simulatorIDs.count < plan.requiredCount {
                let shardIndex = simulatorIDs.count
                let clonedSimulatorID = try cloneManagedShardSimulator(
                    templateSimulatorID: primarySimulatorID,
                    managed: managed,
                    shardIndex: shardIndex,
                    context: context
                )
                simulatorIDs.append(clonedSimulatorID)
                transientSimulatorIDs.append(clonedSimulatorID)
            }
        } catch {
            cleanupTransientSimulators(transientSimulatorIDs, context: context)
            throw error
        }
        return ManualShardSimulatorSelection(
            simulatorIDs: simulatorIDs,
            transientSimulatorIDs: transientSimulatorIDs,
            primaryNeedsBoot: true
        )
    }

    private func shutdownSimulatorForCloneTemplate(simulatorID: String, context: ToolExecutionContext) throws {
        try runtime.shutdownSimulatorForCloneTemplate(simulatorID: simulatorID, context: context)
    }

    private func cloneManagedShardSimulator(
        templateSimulatorID: String,
        managed: ManagedSimulator,
        shardIndex: Int,
        context: ToolExecutionContext
    ) throws -> String {
        try runtime.cloneManagedShardSimulator(
            templateSimulatorID: templateSimulatorID,
            managed: managed,
            shardIndex: shardIndex,
            context: context
        )
    }

    private func shouldRetryManualShardFailure(outcome: TestOutcome, run: ToolResult) -> Bool {
        if runtime.isCancellationResult(run) {
            return false
        }
        switch outcome.resultClass {
        case .runnerBootstrapFailure:
            return runtime.shouldRetryBootstrapFailure(run: run)
        case .artifactFailure:
            return true
        case .success, .buildFailure, .buildTimeout, .testFailure, .testTimeout, .unsupportedDestination, .canceled, .internalError:
            return false
        }
    }

    private func recoverSimulatorForShardRetry(simulatorID: String, context: ToolExecutionContext) throws {
        try runtime.recoverSimulatorForShardRetry(simulatorID: simulatorID, context: context)
    }

    private func cleanupTransientSimulators(_ simulatorIDs: [String], context: ToolExecutionContext) {
        for simulatorID in simulatorIDs {
            deleteTransientSimulatorAfterJob(simulatorID: simulatorID, context: context)
        }
    }

    private func deleteTransientSimulatorAfterJob(simulatorID: String, context: ToolExecutionContext) {
        runtime.deleteTransientSimulatorAfterJob(simulatorID: simulatorID, context: context)
    }

    private func shardSuccessSummary(for mode: ParallelMode, count: Int) -> String {
        switch mode {
        case .hybrid:
            return "Hybrid shards succeeded (\(count) shards)"
        case .manualShards, .serial, .xcodeManaged:
            return "Manual shards succeeded (\(count) shards)"
        }
    }
}
