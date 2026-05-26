import Foundation

protocol ManualShardRuntime: AnyObject {
    func resolveTestProductReference(
        in paths: ExecutionPaths,
        preferredTestPlan: String?,
        context: ToolExecutionContext
    ) -> TestProductReference?
    func missingTestProductReferenceMessage(paths: ExecutionPaths, context: ToolExecutionContext) -> String
    func failAndLog(message: String, exitCode: Int32, logURL: URL, combinedLog: URL) throws -> ToolResult
    func warnAndLog(message: String, logURL: URL, combinedLog: URL) throws
    func runTool(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        environmentOverrides: [String: String]
    ) throws -> ToolResult
    func runAndLog(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext,
        environmentOverrides: [String: String]
    ) throws -> ToolResult
    func runAndLog(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext,
        environmentOverrides: [String: String],
        processStarted: ((Int32) throws -> Void)?
    ) throws -> ToolResult
    func throwIfCanceled(_ result: ToolResult, context: ToolExecutionContext) throws
    func isCancellationResult(_ result: ToolResult) -> Bool
    func commandFailed(_ message: String, output: String) -> XCStewardError
    func shouldRetryBootstrapFailure(run: ToolResult) -> Bool
    func classify(run: ToolResult, resultBundle: URL) -> TestOutcome
    func prepareSimulatorPrivacy(
        simulatorID: String,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext
    ) throws
    func prepareResultStreamIfNeeded(for settings: ResultStreamSettings, path: URL) throws
    func captureSimulatorDiagnostics(
        simulatorID: String,
        outputURL: URL,
        context: ToolExecutionContext
    ) -> String?
    func cleanupSimulatorAfterJob(simulatorID: String, context: ToolExecutionContext)
    func bootSimulator(simulatorID: String, context: ToolExecutionContext) throws
    func shutdownSimulatorForCloneTemplate(simulatorID: String, context: ToolExecutionContext) throws
    func cloneManagedShardSimulator(
        templateSimulatorID: String,
        managed: ManagedSimulator,
        shardIndex: Int,
        context: ToolExecutionContext
    ) throws -> String
    func recoverSimulatorForShardRetry(simulatorID: String, context: ToolExecutionContext) throws
    func deleteTransientSimulatorAfterJob(simulatorID: String, context: ToolExecutionContext)
    func testRunnerEnvironment(
        context: ToolExecutionContext,
        temporaryDirectory: URL,
        phase: String,
        shardID: String?,
        shardIndex: Int?,
        totalShards: Int?
    ) -> [String: String]
    func testIdentifier(_ identifier: String, matchesSkipFilter skipFilter: String) -> Bool
    func parseCreatedSimulatorID(from output: String) -> String?
}

extension ManualShardRuntime {
    func runTool(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext
    ) throws -> ToolResult {
        try runTool(
            tool: tool,
            arguments: arguments,
            timeout: timeout,
            context: context,
            environmentOverrides: [:]
        )
    }

    func runXcodebuildTestAttempt(
        _ attempt: XcodebuildTestAttempt,
        context: ToolExecutionContext,
        processStarted: ((Int32) throws -> Void)? = nil
    ) throws -> ToolResult {
        try prepareSimulatorPrivacy(
            simulatorID: attempt.simulatorID,
            logURL: attempt.logURL,
            combinedLog: attempt.combinedLog,
            context: context
        )
        try prepareResultStreamIfNeeded(for: context.profile.resultStream, path: attempt.resultStream)
        return try runAndLog(
            tool: "xcodebuild",
            arguments: attempt.arguments,
            timeout: context.profile.timeouts.test,
            logURL: attempt.logURL,
            combinedLog: attempt.combinedLog,
            context: context,
            environmentOverrides: testRunnerEnvironment(
                context: context,
                temporaryDirectory: attempt.temporaryDirectory,
                phase: attempt.phase,
                shardID: attempt.shardID,
                shardIndex: attempt.shardIndex,
                totalShards: attempt.totalShards
            ),
            processStarted: processStarted
        )
    }
}

extension JobExecutor: ManualShardRuntime {}
extension JobExecutor: SimulatorLifecycleTooling {}
