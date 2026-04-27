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

    private static func doctorHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] doctor [options]

        Options:
          --project <name>  Restrict checks to a configured project profile.
          --fix             Apply supported remediations automatically.
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

        let request = JobRequest(project: project, testPlan: testPlan, onlyTesting: onlyTesting, simulatorID: explicitSimulator, metadata: [:], wait: wait)
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
            let summary = JobSummary(
                jobID: job.id,
                project: job.project,
                state: .canceled,
                resultClass: .canceled,
                exitCode: nil,
                submittedAt: job.createdAt,
                startedAt: nil,
                finishedAt: finishedAt,
                durationSeconds: 0,
                testPlan: job.request.testPlan,
                onlyTesting: job.request.onlyTesting,
                simulatorID: job.simulatorID,
                counts: nil,
                artifacts: JobArtifacts(xcresult: nil, combinedLog: nil, buildLog: nil, testLog: nil, derivedData: nil, diagnostics: nil),
                summaryLine: "Canceled",
                metadata: job.request.metadata
            )
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
            if let pid = job.processID, pid > 0, pid != workerPID {
                if kill(-pid, SIGTERM) != 0 {
                    kill(pid, SIGTERM)
                }
            }
        }
        let updated = try store.fetchJob(id: jobID) ?? job
        try printJob(updated, json: json)
        return 0
    }

    private func handleDoctor(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        let fix = removeFlag("--fix", from: &arguments)
        let project = consumeOption("--project", from: &arguments)
        let report = try DoctorEngine(environment: environment, store: store).run(project: project, fix: fix)
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
        return JobSummary(
            jobID: job.id,
            project: job.project,
            state: job.state,
            resultClass: job.resultClass,
            exitCode: nil,
            submittedAt: job.createdAt,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            durationSeconds: nil,
            testPlan: job.request.testPlan,
            onlyTesting: job.request.onlyTesting,
            simulatorID: job.simulatorID,
            counts: nil,
            artifacts: JobArtifacts(
                xcresult: root.appendingPathComponent("artifacts/result.xcresult").path,
                combinedLog: root.appendingPathComponent("logs/combined.log").path,
                buildLog: root.appendingPathComponent("logs/build.log").path,
                testLog: root.appendingPathComponent("logs/test.log").path,
                derivedData: root.appendingPathComponent("derived-data").path,
                diagnostics: nil
            ),
            summaryLine: job.state.rawValue.capitalized,
            metadata: job.request.metadata
        )
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
