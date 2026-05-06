import Foundation

public struct XCStewardApp {
    private var environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public mutating func run(arguments inputArguments: [String]) throws -> Int32 {
        var arguments = inputArguments
        let executableName = URL(fileURLWithPath: arguments.first ?? "xcsteward").lastPathComponent
        _ = arguments.first.map { _ in arguments.removeFirst() }
        let stateRoot = resolveStateRoot(arguments: &arguments, environment: environment.processInfo.environment)
        environment.paths = AppPaths(stateRoot: stateRoot)

        guard let command = arguments.first else {
            throw XCStewardError.usage("""
            No command provided.

            \(Self.rootHelp(executableName: executableName))
            """)
        }

        if isHelpRequest(command) {
            let topic = arguments.dropFirst().first
            print(try helpText(for: topic, executableName: executableName))
            return 0
        }

        arguments.removeFirst()

        if containsHelpFlag(arguments) {
            print(try helpText(for: command, executableName: executableName))
            return 0
        }

        switch command {
        case "submit":
            return try handleSubmit(arguments: arguments, store: try StateStore(environment: environment))
        case "status":
            return try handleStatus(arguments: arguments, store: try StateStore(environment: environment))
        case "jobs":
            return try handleJobs(arguments: arguments, store: try StateStore(environment: environment))
        case "logs":
            return try handleLogs(arguments: arguments, store: try StateStore(environment: environment))
        case "artifacts":
            return try handleArtifacts(arguments: arguments, store: try StateStore(environment: environment))
        case "cancel":
            return try handleCancel(arguments: arguments, store: try StateStore(environment: environment))
        case "cleanup":
            return try handleCleanup(arguments: arguments, store: try StateStore(environment: environment))
        case "doctor":
            return try handleDoctor(arguments: arguments, store: try StateStore(environment: environment))
        case "_internal":
            return try handleInternal(arguments: arguments, store: try StateStore(environment: environment))
        default:
            throw XCStewardError.usage("""
            Unknown command: \(command)

            \(Self.rootHelp(executableName: executableName))
            """)
        }
    }

    private func isHelpRequest(_ argument: String) -> Bool {
        argument == "help" || argument == "--help" || argument == "-h"
    }

    private func containsHelpFlag(_ arguments: [String]) -> Bool {
        arguments.contains("--help") || arguments.contains("-h")
    }

    private func helpText(for command: String?, executableName: String) throws -> String {
        if let command {
            switch command {
            case "submit":
                return Self.submitHelp(executableName: executableName)
            case "status":
                return Self.statusHelp(executableName: executableName)
            case "jobs":
                return Self.jobsHelp(executableName: executableName)
            case "logs":
                return Self.logsHelp(executableName: executableName)
            case "artifacts":
                return Self.artifactsHelp(executableName: executableName)
            case "cancel":
                return Self.cancelHelp(executableName: executableName)
            case "cleanup":
                return Self.cleanupHelp(executableName: executableName)
            case "doctor":
                return Self.doctorHelp(executableName: executableName)
            case "_internal":
                return Self.internalHelp(executableName: executableName)
            default:
                throw XCStewardError.usage("""
                Unknown command: \(command)

                \(Self.rootHelp(executableName: executableName))
                """)
            }
        }
        return Self.rootHelp(executableName: executableName)
    }

    private static func rootHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] <command> [options]
          \(executableName) --help
          \(executableName) help [command]

        Commands:
          submit     Queue a test job for a configured project.
          status     Show a job summary.
          jobs       List known jobs.
          logs       Print the combined log for a job.
          artifacts  Show artifact paths for a job.
          cancel     Cancel a queued or running job.
          cleanup    Remove old terminal job records and artifact directories.
          doctor     Run environment and project diagnostics.

        Global options:
          --state-root <path>  Use a specific state directory.
          --help, -h           Show help for the CLI or a command.

        Environment:
          XCSTEWARD_HOME       Default state root when --state-root is omitted.
        """
    }

    private static func submitHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] submit --project <name> [options]

        Options:
          --project <name>            Project profile name to run.
          --wait                      Block until the job reaches a terminal state.
          --json                      Print the job summary as JSON.
          --test-plan <name>          Override the profile's default test plan.
          --simulator-id <id>         Override the profile's simulator selection.
          --only-testing <identifier> Restrict execution to a test target or test case. Repeatable.
          --skip-testing <identifier> Exclude a test target or test case. Repeatable.
          --only-test-configuration <name>
                                      Restrict execution to a test plan configuration. Repeatable.
          --skip-test-configuration <name>
                                      Exclude a test plan configuration. Repeatable.
          --help, -h                  Show this command help.
        """
    }

    private static func statusHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] status <job-id> [--json]

        Options:
          --json      Print the job summary as JSON.
          --help, -h  Show this command help.
        """
    }

    private static func jobsHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] jobs [--json]

        Options:
          --json      Print job summaries as JSON.
          --help, -h  Show this command help.
        """
    }

    private static func logsHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] logs <job-id>

        Options:
          --help, -h  Show this command help.
        """
    }

    private static func artifactsHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] artifacts <job-id> [--json]

        Options:
          --json      Print artifact paths as JSON.
          --help, -h  Show this command help.
        """
    }

    private static func cancelHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] cancel <job-id> [--json]

        Options:
          --json      Print the updated job summary as JSON.
          --help, -h  Show this command help.
        """
    }

    private static func cleanupHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] cleanup [options]

        Options:
          --apply                 Delete selected terminal jobs. Defaults to dry-run.
          --dry-run               Report selected terminal jobs without deleting.
          --older-than <duration> Select terminal jobs older than this age. Default: 7d.
                                  Supports s, m, h, and d suffixes.
          --keep-last <count>     Always keep this many newest terminal jobs. Default: 20.
          --max-total-size <size> Select oldest eligible jobs until terminal job bytes are
                                  under this budget. Supports b, kb, mb, and gb suffixes.
          --json                  Print cleanup report as JSON.
          --help, -h              Show this command help.
        """
    }

    private static func doctorHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] doctor [options]

        Options:
          --project <name>  Restrict checks to a configured project profile.
          --fix             Apply safe XCSteward-scoped remediations automatically.
          --fix-global      Also apply broad CoreSimulator remediations. Implies --fix.
          --json            Print the doctor report as JSON.
          --help, -h        Show this command help.
        """
    }

    private static func internalHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] _internal run-worker

        Options:
          --help, -h  Show this command help.
        """
    }

    private func handleSubmit(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        guard let project = consumeOption("--project", from: &arguments) else {
            throw XCStewardError.usage("submit requires --project")
        }
        let wait = removeFlag("--wait", from: &arguments)
        let json = removeFlag("--json", from: &arguments)
        let testPlan = consumeOption("--test-plan", from: &arguments)
        let explicitSimulator = consumeOption("--simulator-id", from: &arguments)
        var onlyTesting: [String] = []
        while let value = consumeOption("--only-testing", from: &arguments) {
            onlyTesting.append(value)
        }
        var skipTesting: [String] = []
        while let value = consumeOption("--skip-testing", from: &arguments) {
            skipTesting.append(value)
        }
        var onlyTestConfigurations: [String] = []
        while let value = consumeOption("--only-test-configuration", from: &arguments) {
            onlyTestConfigurations.append(value)
        }
        var skipTestConfigurations: [String] = []
        while let value = consumeOption("--skip-test-configuration", from: &arguments) {
            skipTestConfigurations.append(value)
        }

        let request = JobRequest(
            project: project,
            testPlan: testPlan,
            onlyTesting: onlyTesting,
            skipTesting: skipTesting,
            onlyTestConfigurations: onlyTestConfigurations,
            skipTestConfigurations: skipTestConfigurations,
            simulatorID: explicitSimulator,
            metadata: [:],
            wait: wait
        )
        let now = environment.clock.now().timeIntervalSince1970
        let jobID = environment.uuidProvider.makeUUID()
        let jobDirectory = environment.paths.jobsRoot.appendingPathComponent(jobID)
        try environment.fileSystem.createDirectory(jobDirectory)
        try environment.fileSystem.writeData(try jsonData(request), to: jobDirectory.appendingPathComponent("request.json"))
        let record = JobRecord(id: jobID, project: project, state: .queued, resultClass: nil, request: request, summary: nil, jobDirectory: jobDirectory.path, createdAt: now, startedAt: nil, finishedAt: nil, processID: nil, simulatorID: nil, cancelRequested: false)
        try store.createJob(record)

        if wait {
            try runWorkerInlineIfPossible(store: store)
            let terminal = try waitForJob(id: jobID, store: store)
            try printJob(terminal, json: json)
            return terminal.state == .succeeded ? 0 : 1
        }

        try spawnWorkerIfNeeded()
        let current = try store.fetchJob(id: jobID) ?? record
        try printJob(current, json: json)
        return 0
    }

    private func handleStatus(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        guard let jobID = arguments.first else {
            throw XCStewardError.usage("status requires a job id")
        }
        guard let job = try store.fetchJob(id: jobID) else {
            throw XCStewardError.notFound("Job \(jobID) not found")
        }
        try printJob(job, json: json)
        return job.state == .succeeded ? 0 : (job.state.isTerminal ? 1 : 0)
    }

    private func handleJobs(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        let jobs = try store.listJobs()
        if json {
            let summaries = jobs.map(jobOutput(from:))
            FileHandle.standardOutput.write(try jsonData(summaries))
        } else {
            for job in jobs {
                print("\(job.id) \(job.state.rawValue)")
            }
        }
        return 0
    }

    private func handleLogs(arguments: [String], store: StateStore) throws -> Int32 {
        guard let jobID = arguments.first, let job = try store.fetchJob(id: jobID) else {
            throw XCStewardError.notFound("logs requires a valid job id")
        }
        let summary = try loadSummary(for: job)
        if let log = summary.artifacts.combinedLog {
            let data = try environment.fileSystem.readData(from: URL(fileURLWithPath: log))
            FileHandle.standardOutput.write(data)
        }
        return 0
    }

    private func handleArtifacts(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        guard let jobID = arguments.first, let job = try store.fetchJob(id: jobID) else {
            throw XCStewardError.notFound("artifacts requires a valid job id")
        }
        let summary = try loadSummary(for: job)
        if json {
            FileHandle.standardOutput.write(try jsonData(summary.artifacts))
        } else {
            print(summary.artifacts.xcresult ?? "")
        }
        return 0
    }

    private func handleCancel(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        guard let jobID = arguments.first, let job = try store.fetchJob(id: jobID) else {
            throw XCStewardError.notFound("cancel requires a valid job id")
        }
        if job.state == .queued {
            let finishedAt = environment.clock.now().timeIntervalSince1970
            let summary = JobSummaryFactory().queuedCanceledSummary(job: job, finishedAt: finishedAt)
            try store.updateJob(
                id: jobID,
                patch: JobStatePatch(
                    state: .canceled,
                    resultClass: .canceled,
                    summary: summary,
                    finishedAt: finishedAt,
                    cancelRequested: true
                )
            )
        } else {
            try store.requestCancel(jobID: jobID)
            let workerPID = try store.currentLease()?.pid
            let activeProcessID = (try store.fetchJob(id: jobID))?.processID ?? job.processID
            if let pid = activeProcessID, pid > 0, pid != workerPID {
                _ = kill(-pid, SIGTERM)
                _ = kill(pid, SIGTERM)
            }
        }
        let updated = try store.fetchJob(id: jobID) ?? job
        try printJob(updated, json: json)
        return 0
    }

    private func handleCleanup(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        let apply = removeFlag("--apply", from: &arguments)
        let dryRunFlag = removeFlag("--dry-run", from: &arguments)
        if apply && dryRunFlag {
            throw XCStewardError.usage("cleanup cannot combine --apply and --dry-run")
        }
        let olderThan = try consumeOption("--older-than", from: &arguments)
            .map(parseCleanupDuration(_:)) ?? (7 * 24 * 60 * 60)
        let keepLast = try consumeOption("--keep-last", from: &arguments)
            .map { try parseNonNegativeInteger($0, option: "--keep-last") } ?? 20
        let maxTotalBytes = try consumeOption("--max-total-size", from: &arguments)
            .map(parseCleanupSize(_:))
        guard arguments.isEmpty else {
            throw XCStewardError.usage("cleanup received unexpected arguments: \(arguments.joined(separator: " "))")
        }

        let report = try CleanupService(environment: environment).cleanupTerminalJobs(
            store: store,
            olderThanSeconds: olderThan,
            keepLast: keepLast,
            maxTotalBytes: maxTotalBytes,
            dryRun: !apply
        )
        if json {
            FileHandle.standardOutput.write(try jsonData(report))
        } else if report.dryRun {
            print("Dry run: \(report.candidateCount) terminal job(s) eligible for cleanup")
            for candidate in report.candidates {
                let bytes = candidate.bytes.map(String.init) ?? "unknown"
                print("\(candidate.jobID) \(candidate.state.rawValue) \(candidate.reason) \(bytes) \(candidate.jobDirectory)")
            }
        } else {
            print("Deleted \(report.deletedCount) terminal job(s)")
        }
        return 0
    }

    private func parseCleanupDuration(_ value: String) throws -> TimeInterval {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw XCStewardError.usage("cleanup --older-than requires a duration")
        }
        let unit = trimmed.last.map(String.init) ?? "s"
        let multiplier: TimeInterval
        let numberText: String
        switch unit {
        case "s":
            multiplier = 1
            numberText = String(trimmed.dropLast())
        case "m":
            multiplier = 60
            numberText = String(trimmed.dropLast())
        case "h":
            multiplier = 60 * 60
            numberText = String(trimmed.dropLast())
        case "d":
            multiplier = 24 * 60 * 60
            numberText = String(trimmed.dropLast())
        default:
            multiplier = 1
            numberText = trimmed
        }
        guard let amount = Double(numberText), amount >= 0 else {
            throw XCStewardError.usage("cleanup --older-than must be a non-negative duration")
        }
        return amount * multiplier
    }

    private func parseNonNegativeInteger(_ value: String, option: String) throws -> Int {
        guard let parsed = Int(value), parsed >= 0 else {
            throw XCStewardError.usage("\(option) must be a non-negative integer")
        }
        return parsed
    }

    private func parseCleanupSize(_ value: String) throws -> Int64 {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw XCStewardError.usage("cleanup --max-total-size requires a size")
        }
        let units: [(suffix: String, multiplier: Double)] = [
            ("gb", 1_073_741_824),
            ("g", 1_073_741_824),
            ("mb", 1_048_576),
            ("m", 1_048_576),
            ("kb", 1_024),
            ("k", 1_024),
            ("b", 1),
        ]
        let match = units.first { trimmed.hasSuffix($0.suffix) }
        let numberText = match.map { String(trimmed.dropLast($0.suffix.count)) } ?? trimmed
        let multiplier = match?.multiplier ?? 1
        guard let amount = Double(numberText), amount >= 0, amount <= Double(Int64.max) / multiplier else {
            throw XCStewardError.usage("cleanup --max-total-size must be a non-negative size")
        }
        return Int64((amount * multiplier).rounded(.down))
    }

    private func handleDoctor(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        let fixGlobal = removeFlag("--fix-global", from: &arguments)
        let fix = removeFlag("--fix", from: &arguments) || fixGlobal
        let project = consumeOption("--project", from: &arguments)
        let report = try DoctorEngine(environment: environment, store: store).run(
            project: project,
            fixOptions: DoctorFixOptions(applySafeFixes: fix, applyGlobalFixes: fixGlobal)
        )
        if json {
            FileHandle.standardOutput.write(try jsonData(report))
        } else {
            print(report.overallStatus.rawValue)
        }
        return report.overallStatus == .fail ? 1 : 0
    }

    private func handleInternal(arguments: [String], store: StateStore) throws -> Int32 {
        guard arguments.first == "run-worker" else {
            throw XCStewardError.usage("Unknown internal command")
        }
        try Worker(environment: environment, store: store).run()
        return 0
    }

    private func waitForJob(id: String, store: StateStore) throws -> JobRecord {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let job = try store.fetchJob(id: id), job.state.isTerminal {
                return job
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCStewardError.commandFailed("Timed out waiting for job \(id)")
    }

    private func runWorkerInlineIfPossible(store: StateStore) throws {
        try Worker(environment: environment, store: store).run()
    }

    private func spawnWorkerIfNeeded() throws {
        let current = try StateStore(environment: environment).currentLease()
        if let current, isPIDAlive(current.pid) {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment.processInfo.arguments.first ?? CommandLine.arguments[0])
        process.arguments = ["--state-root", environment.paths.stateRoot.path, "_internal", "run-worker"]
        process.environment = environment.processInfo.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let lease = try StateStore(environment: environment).currentLease(), isPIDAlive(lease.pid) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func jobOutput(from job: JobRecord) -> [String: AnyEncodable] {
        if let summary = try? loadSummary(for: job) {
            return [
                "job_id": AnyEncodable(summary.jobID),
                "project": AnyEncodable(summary.project),
                "state": AnyEncodable(summary.state.rawValue),
                "result_class": AnyEncodable(summary.resultClass?.rawValue),
            ]
        }
        return [
            "job_id": AnyEncodable(job.id),
            "project": AnyEncodable(job.project),
            "state": AnyEncodable(job.state.rawValue),
            "result_class": AnyEncodable(job.resultClass?.rawValue),
        ]
    }

    private func printJob(_ job: JobRecord, json: Bool) throws {
        let summary = try loadSummary(for: job)
        if json {
            FileHandle.standardOutput.write(try jsonData(summary))
        } else {
            print(summary.summaryLine)
        }
    }

    private func loadSummary(for job: JobRecord) throws -> JobSummary {
        if let summary = job.summary {
            return summary
        }
        let root = URL(fileURLWithPath: job.jobDirectory)
        let summaryURL = root.appendingPathComponent("artifacts/summary.json")
        if environment.fileSystem.fileExists(summaryURL) {
            return try decodeJSON(JobSummary.self, from: environment.fileSystem.readData(from: summaryURL))
        }
        return JobSummaryFactory().fallbackSummary(job: job)
    }
}

private struct AnyEncodable: Encodable {
    private let encodeFunction: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T?) {
        self.encodeFunction = { encoder in
            var container = encoder.singleValueContainer()
            if let value {
                try container.encode(value)
            } else {
                try container.encodeNil()
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeFunction(encoder)
    }
}
