import Darwin
import Foundation

private typealias CLICommandHandler = (inout XCStewardApp, [String], StateStore) throws -> Int32

private struct CLICommandDefinition {
    var name: String
    var rootHelpLine: String?
    var help: (String) -> String
    var handler: CLICommandHandler
}

public struct XCStewardApp {
    private var environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public mutating func run(arguments inputArguments: [String]) throws -> Int32 {
        var arguments = inputArguments
        let executableName = URL(fileURLWithPath: arguments.first ?? "xcsteward").lastPathComponent
        _ = arguments.first.map { _ in arguments.removeFirst() }
        let stateRoot = try resolveStateRoot(arguments: &arguments, environment: environment.processInfo.environment)
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

        guard let definition = Self.command(named: command) else {
            throw XCStewardError.usage("""
            Unknown command: \(command)

            \(Self.rootHelp(executableName: executableName))
            """)
        }
        return try definition.handler(&self, arguments, try StateStore(environment: environment))
    }

    private func isHelpRequest(_ argument: String) -> Bool {
        argument == "help" || argument == "--help" || argument == "-h"
    }

    private func containsHelpFlag(_ arguments: [String]) -> Bool {
        arguments.contains("--help") || arguments.contains("-h")
    }

    private func helpText(for command: String?, executableName: String) throws -> String {
        if let command {
            guard let definition = Self.command(named: command) else {
                throw XCStewardError.usage("""
                Unknown command: \(command)

                \(Self.rootHelp(executableName: executableName))
                """)
            }
            return definition.help(executableName)
        }
        return Self.rootHelp(executableName: executableName)
    }

    private static var commandTable: [CLICommandDefinition] {
        [
            CLICommandDefinition(
                name: "submit",
                rootHelpLine: "  submit     Queue a test job for a configured project.",
                help: submitHelp,
                handler: { app, arguments, store in try app.handleSubmit(arguments: arguments, store: store) }
            ),
            CLICommandDefinition(
                name: "status",
                rootHelpLine: "  status     Show a job summary.",
                help: statusHelp,
                handler: { app, arguments, store in try app.handleStatus(arguments: arguments, store: store) }
            ),
            CLICommandDefinition(
                name: "jobs",
                rootHelpLine: "  jobs       List known jobs.",
                help: jobsHelp,
                handler: { app, arguments, store in try app.handleJobs(arguments: arguments, store: store) }
            ),
            CLICommandDefinition(
                name: "logs",
                rootHelpLine: "  logs       Print the combined log for a job.",
                help: logsHelp,
                handler: { app, arguments, store in try app.handleLogs(arguments: arguments, store: store) }
            ),
            CLICommandDefinition(
                name: "artifacts",
                rootHelpLine: "  artifacts  Show artifact paths for a job.",
                help: artifactsHelp,
                handler: { app, arguments, store in try app.handleArtifacts(arguments: arguments, store: store) }
            ),
            CLICommandDefinition(
                name: "cancel",
                rootHelpLine: "  cancel     Cancel a queued or running job.",
                help: cancelHelp,
                handler: { app, arguments, store in try app.handleCancel(arguments: arguments, store: store) }
            ),
            CLICommandDefinition(
                name: "cleanup",
                rootHelpLine: "  cleanup    Remove old terminal job records and artifact directories.",
                help: cleanupHelp,
                handler: { app, arguments, store in try app.handleCleanup(arguments: arguments, store: store) }
            ),
            CLICommandDefinition(
                name: "doctor",
                rootHelpLine: "  doctor     Run environment and project diagnostics.",
                help: doctorHelp,
                handler: { app, arguments, store in try app.handleDoctor(arguments: arguments, store: store) }
            ),
            CLICommandDefinition(
                name: "_internal",
                rootHelpLine: nil,
                help: internalHelp,
                handler: { app, arguments, store in try app.handleInternal(arguments: arguments, store: store) }
            ),
        ]
    }

    private static func command(named name: String) -> CLICommandDefinition? {
        commandTable.first { $0.name == name }
    }

    private static func rootHelp(executableName: String) -> String {
        let visibleCommands = commandTable
            .compactMap(\.rootHelpLine)
            .joined(separator: "\n")
        return """
        Usage:
          \(executableName) [--state-root <path>] <command> [options]
          \(executableName) --help
          \(executableName) help [command]

        Commands:
        \(visibleCommands)

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
          --wait-timeout <seconds>    Max seconds to wait with --wait. Default: 30.
          --json                      Print the job summary as JSON.
          --progress                  Emit live JSON progress events to stderr.
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
          --dangerously-confirm-global-coresimulator-cleanup
                           Required with --fix-global before broad CoreSimulator cleanup runs.
          --json            Print the doctor report as JSON.
          --progress        Emit live JSON progress events to stderr.
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
        let options = try SubmitCommandOptions.parse(arguments: arguments)
        let request = options.request
        let workerExecutableURL = try workerExecutableURLIfSpawnRequired(store: store)
        let now = environment.clock.now().timeIntervalSince1970
        let progress = CLIProgressReporter(enabled: options.progress, clock: environment.clock)
        let jobID = environment.uuidProvider.makeUUID()
        let jobDirectory = environment.paths.jobsRoot.appendingPathComponent(jobID)
        try environment.fileSystem.createDirectory(jobDirectory)
        try environment.fileSystem.writeData(try jsonData(request), to: jobDirectory.appendingPathComponent("request.json"))
        let record = JobRecord(id: jobID, project: request.project, state: .queued, resultClass: nil, request: request, summary: nil, jobDirectory: jobDirectory.path, createdAt: now, startedAt: nil, finishedAt: nil, processID: nil, simulatorID: nil, cancelRequested: false)
        try store.createJob(record)
        progress.emit("job_queued", job: record)

        if request.wait {
            do {
                try spawnWorkerIfNeeded(executableURL: workerExecutableURL)
                progress.emit("worker_ready", job: try store.fetchJob(id: jobID) ?? record)
            } catch {
                return try failJobAfterWorkerLaunchFailure(error, job: record, store: store, json: options.json, progress: progress)
            }
            let terminal = try waitForJob(id: jobID, store: store, timeout: options.waitTimeout, progress: progress)
            try printJob(terminal, json: options.json)
            return terminal.state == .succeeded ? 0 : 1
        }

        do {
            try spawnWorkerIfNeeded(executableURL: workerExecutableURL)
            progress.emit("worker_ready", job: try store.fetchJob(id: jobID) ?? record)
        } catch {
            return try failJobAfterWorkerLaunchFailure(error, job: record, store: store, json: options.json, progress: progress)
        }
        let current = try store.fetchJob(id: jobID) ?? record
        try printJob(current, json: options.json)
        return 0
    }

    private func handleStatus(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        guard let jobID = arguments.first else {
            throw XCStewardError.usage("status requires a job id")
        }
        arguments.removeFirst()
        guard arguments.isEmpty else {
            throw XCStewardError.usage("status received unexpected arguments: \(arguments.joined(separator: " "))")
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
        guard arguments.isEmpty else {
            throw XCStewardError.usage("jobs received unexpected arguments: \(arguments.joined(separator: " "))")
        }
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
        var arguments = arguments
        guard let jobID = arguments.first else {
            throw XCStewardError.usage("logs requires a job id")
        }
        arguments.removeFirst()
        guard arguments.isEmpty else {
            throw XCStewardError.usage("logs received unexpected arguments: \(arguments.joined(separator: " "))")
        }
        guard let job = try store.fetchJob(id: jobID) else {
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
        guard let jobID = arguments.first else {
            throw XCStewardError.usage("artifacts requires a job id")
        }
        arguments.removeFirst()
        guard arguments.isEmpty else {
            throw XCStewardError.usage("artifacts received unexpected arguments: \(arguments.joined(separator: " "))")
        }
        guard let job = try store.fetchJob(id: jobID) else {
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
        guard let jobID = arguments.first else {
            throw XCStewardError.usage("cancel requires a job id")
        }
        arguments.removeFirst()
        guard arguments.isEmpty else {
            throw XCStewardError.usage("cancel received unexpected arguments: \(arguments.joined(separator: " "))")
        }
        guard let job = try store.fetchJob(id: jobID) else {
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
        let progress = CLIProgressReporter(enabled: removeFlag("--progress", from: &arguments), clock: environment.clock)
        let fixGlobal = removeFlag("--fix-global", from: &arguments)
        let confirmGlobalCleanup = removeFlag("--dangerously-confirm-global-coresimulator-cleanup", from: &arguments)
        let fix = removeFlag("--fix", from: &arguments) || fixGlobal
        let project = try consumeOption("--project", from: &arguments)
        guard arguments.isEmpty else {
            throw XCStewardError.usage("doctor received unexpected arguments: \(arguments.joined(separator: " "))")
        }
        if confirmGlobalCleanup && !fixGlobal {
            throw XCStewardError.usage("doctor --dangerously-confirm-global-coresimulator-cleanup requires --fix-global")
        }
        if fixGlobal && !confirmGlobalCleanup {
            throw XCStewardError.usage(
                "doctor --fix-global requires --dangerously-confirm-global-coresimulator-cleanup before broad CoreSimulator cleanup can run"
            )
        }
        let report = try DoctorEngine(environment: environment, store: store).run(
            project: project,
            fixOptions: DoctorFixOptions(applySafeFixes: fix, applyGlobalFixes: fixGlobal),
            progress: { event in
                progress.emit(
                    event.event,
                    checkID: event.checkID,
                    status: event.status
                )
            }
        )
        if json {
            FileHandle.standardOutput.write(try jsonData(report))
        } else {
            printDoctorReport(report)
        }
        return report.overallStatus == .fail ? 1 : 0
    }

    private func handleInternal(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        guard arguments.first == "run-worker" else {
            throw XCStewardError.usage("Unknown internal command")
        }
        arguments.removeFirst()
        guard arguments.isEmpty else {
            throw XCStewardError.usage("_internal received unexpected arguments: \(arguments.joined(separator: " "))")
        }
        signal(SIGINT, SIG_IGN)
        try Worker(environment: environment, store: store).run()
        return 0
    }

    private func waitForJob(
        id: String,
        store: StateStore,
        timeout: TimeInterval,
        progress: CLIProgressReporter
    ) throws -> JobRecord {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSignature: String?
        var nextHeartbeat = environment.clock.now().addingTimeInterval(5)
        while Date() < deadline {
            if let job = try store.fetchJob(id: id) {
                let signature = [
                    job.state.rawValue,
                    job.resultClass?.rawValue ?? "",
                    job.processID.map(String.init) ?? "",
                    job.simulatorID ?? "",
                ].joined(separator: "|")
                let now = environment.clock.now()
                if signature != lastSignature || now >= nextHeartbeat {
                    progress.emit("job_status", job: job)
                    lastSignature = signature
                    nextHeartbeat = now.addingTimeInterval(5)
                }
                if job.state.isTerminal {
                    progress.emit("job_terminal", job: job)
                    return job
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if let job = try store.fetchJob(id: id),
           let terminalJob = terminalJobFromPersistedSummary(job) {
            progress.emit("job_terminal", job: terminalJob)
            return terminalJob
        }
        if let job = try store.fetchJob(id: id) {
            progress.emit("wait_timeout", job: job)
        }
        throw XCStewardError.commandFailed("Timed out waiting for job \(id)")
    }

    private func terminalJobFromPersistedSummary(_ job: JobRecord) -> JobRecord? {
        let root = URL(fileURLWithPath: job.jobDirectory)
        let summaryURL = root.appendingPathComponent("artifacts/summary.json")
        guard environment.fileSystem.fileExists(summaryURL) else {
            return nil
        }
        guard let data = try? environment.fileSystem.readData(from: summaryURL),
              let summary = try? decodeJSON(JobSummary.self, from: data) else {
            return nil
        }
        guard summary.state.isTerminal else {
            return nil
        }
        var terminalJob = job
        terminalJob.state = summary.state
        terminalJob.resultClass = summary.resultClass
        terminalJob.summary = summary
        terminalJob.startedAt = summary.startedAt
        terminalJob.finishedAt = summary.finishedAt
        terminalJob.simulatorID = summary.simulatorID
        return terminalJob
    }

    private func spawnWorkerIfNeeded(executableURL preflightExecutableURL: URL?) throws {
        let current = try StateStore(environment: environment).currentLease()
        if let current, isPIDAlive(current.pid) {
            return
        }
        let executableURL: URL
        if let preflightExecutableURL {
            executableURL = preflightExecutableURL
        } else {
            executableURL = try resolvedCurrentExecutableURL()
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--state-root", environment.paths.stateRoot.path, "_internal", "run-worker"]
        process.environment = environment.processInfo.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let lease = try StateStore(environment: environment).currentLease(), isPIDAlive(lease.pid) {
                return
            }
            if !process.isRunning {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if !process.isRunning {
            throw XCStewardError.commandFailed(
                "XCSteward worker launched from \(executableURL.path) exited before acquiring the queue lease"
            )
        }
        throw XCStewardError.commandFailed(
            "XCSteward worker launched from \(executableURL.path) did not acquire the queue lease within 5 seconds"
        )
    }

    private func workerExecutableURLIfSpawnRequired(store: StateStore) throws -> URL? {
        if let current = try store.currentLease(), isPIDAlive(current.pid) {
            return nil
        }
        return try resolvedCurrentExecutableURL()
    }

    private func resolvedCurrentExecutableURL() throws -> URL {
        if let executableURL = try? resolvedExecutablePathFromProcessImage() {
            return executableURL
        }
        if let bundleExecutableURL = Bundle.main.executableURL {
            return try canonicalExecutableURL(bundleExecutableURL)
        }
        throw XCStewardError.commandFailed("Unable to resolve the XCSteward executable for worker launch")
    }

    private func resolvedExecutablePathFromProcessImage() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &size)
        }
        guard result == 0 else {
            throw XCStewardError.commandFailed("Unable to read the current XCSteward executable path")
        }
        let path = buffer.withUnsafeBufferPointer { pointer -> String in
            guard let baseAddress = pointer.baseAddress else {
                return ""
            }
            return String(cString: baseAddress)
        }
        return try canonicalExecutableURL(URL(fileURLWithPath: path))
    }

    private func canonicalExecutableURL(_ url: URL) throws -> URL {
        let absoluteURL = url.path.hasPrefix("/")
            ? url
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(url.path)
        guard let resolvedPointer = realpath(absoluteURL.path, nil) else {
            let reason = String(cString: strerror(errno))
            throw XCStewardError.commandFailed(
                "Unable to resolve the XCSteward executable at \(absoluteURL.path): \(reason)"
            )
        }
        defer { free(resolvedPointer) }
        let resolvedPath = String(cString: resolvedPointer)
        guard FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            throw XCStewardError.commandFailed(
                "Resolved XCSteward executable is not executable: \(resolvedPath)"
            )
        }
        return URL(fileURLWithPath: resolvedPath)
    }

    private func failJobAfterWorkerLaunchFailure(
        _ error: Error,
        job: JobRecord,
        store: StateStore,
        json: Bool,
        progress: CLIProgressReporter
    ) throws -> Int32 {
        let failure = XCStewardError.commandFailed("Unable to launch XCSteward worker for job \(job.id): \(error)")
        let finished = environment.clock.now().timeIntervalSince1970
        let summary = JobSummaryFactory().preExecutionFailureSummary(
            job: job,
            error: failure,
            resultClass: .runnerBootstrapFailure,
            finishedAt: finished
        )
        try? persistPreExecutionFailureEvidence(summary: summary, job: job)
        try store.updateJob(
            id: job.id,
            patch: JobStatePatch(
                state: .failed,
                resultClass: .runnerBootstrapFailure,
                summary: summary,
                startedAt: summary.startedAt,
                finishedAt: finished,
                simulatorID: job.simulatorID
            )
        )
        let failedJob = try store.fetchJob(id: job.id) ?? job
        progress.emit("worker_launch_failed", job: failedJob)
        try printJob(failedJob, json: json)
        return 1
    }

    private func persistPreExecutionFailureEvidence(summary: JobSummary, job: JobRecord) throws {
        let paths = ExecutionPaths(job: job)
        try paths.createDirectories(using: environment.fileSystem)
        try environment.fileSystem.writeData(try jsonData(summary), to: paths.summary)
        try environment.fileSystem.writeData(
            try jsonData(PreExecutionFailureRunMetadata(summary: summary)),
            to: paths.runMetadata
        )
        try environment.fileSystem.appendData(Data("\(summary.summaryLine)\n".utf8), to: paths.combinedLog)
    }

    private func printDoctorReport(_ report: DoctorReport) {
        print(report.overallStatus.rawValue)
        for check in report.checks where check.status != .pass || check.fixed {
            let fixed = check.fixed ? " fixed" : ""
            print("\(check.status.rawValue) \(check.id)\(fixed): \(check.message)")
            if let manualAction = check.manualAction {
                print("  action: \(manualAction)")
            }
            if let evidencePath = check.evidencePath {
                print("  evidence: \(evidencePath)")
            }
            if let failureExcerpt = check.failureExcerpt {
                print("  detail: \(failureExcerpt)")
            }
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
