// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Darwin
import Foundation

private typealias CLICommandHandler = (inout XCStewardApp, [String], StateStore) throws -> Int32

private struct CLICommandDefinition {
    var name: String
    var rootHelpLine: String?
    var help: (String) -> String
    var handler: CLICommandHandler
}

private struct ProjectListDocument: Encodable {
    var stateRoot: String
    var projectsRoot: String
    var projects: [ProjectReferenceDocument]
    var schemaVersion: Int = xcstewardSchemaVersion
}

private struct ProjectReferenceDocument: Encodable {
    var name: String
    var path: String
    var loadStatus: String
    var errorCode: String?
    var errorMessage: String?
    var repoRoot: String?
    var projectPath: String?
    var workspacePath: String?
    var scheme: String?
}

private struct ProfileShowDocument: Encodable {
    var path: String
    var profile: ProjectProfile
    var schemaVersion: Int = xcstewardSchemaVersion
}

private struct ProfileInitDocument: Encodable {
    var profilePath: String
    var created: Bool
    var warnings: [String]
    var nextCommands: [String]
    var profile: ProjectProfile
    var schemaVersion: Int = xcstewardSchemaVersion
}

private struct DetectedProfileTarget {
    var containerKey: String
    var containerPath: String
    var scheme: String
    var availableSchemes: [String]
}

private struct ManagedSimulatorInitOptions {
    var name: String
    var deviceType: String
    var runtime: String
}

private struct ExplainDocument: Encodable {
    var jobID: String
    var project: String
    var state: JobState
    var resultClass: ResultClass?
    var exitCode: Int32?
    var summaryLine: String
    var retryPolicy: ExplainRetryPolicy
    var recommendedAction: String
    var artifacts: JobArtifacts
    var failedTests: [ExplainFailedTest]
    var buildIssues: [ExplainIssue]
    var logExcerpts: [ExplainLogExcerpt]
    var warnings: [String]
    var summary: JobSummary
    var schemaVersion: Int = xcstewardSchemaVersion
}

private struct ExplainRetryPolicy: Encodable {
    var autoRetry: Bool
    var maxAutoRetries: Int
    var reason: String
}

private struct ExplainFailedTest: Encodable {
    var className: String
    var name: String
    var failureKind: String
    var message: String?
}

private struct ExplainIssue: Encodable {
    var source: String
    var path: String
    var lineNumber: Int
    var text: String
}

private struct ExplainLogExcerpt: Encodable {
    var source: String
    var path: String
    var lineCount: Int
    var excerpt: String
}

private struct HumanProgressUpdate {
    var line: String
    var signature: String
}

private struct HumanCommandProgress {
    var activePhase: String?
    var lastEventTimestamp: Double?
    var lastEventName: String?
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
                name: "projects",
                rootHelpLine: "  projects   List configured project profiles.",
                help: projectsHelp,
                handler: { app, arguments, store in try app.handleProjects(arguments: arguments, store: store) }
            ),
            CLICommandDefinition(
                name: "profile",
                rootHelpLine: "  profile    Show or initialize project profiles.",
                help: profileHelp,
                handler: { app, arguments, store in try app.handleProfile(arguments: arguments, store: store) }
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
                name: "explain",
                rootHelpLine: "  explain    Explain a job outcome and useful evidence.",
                help: explainHelp,
                handler: { app, arguments, store in try app.handleExplain(arguments: arguments, store: store) }
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
          --env <KEY=VALUE>           Override or add an environment variable for this job. Repeatable.
          --only-testing <identifier> Restrict execution to a test target or test case. Repeatable.
          --skip-testing <identifier> Exclude a test target or test case. Repeatable.
          --only-test-configuration <name>
                                      Restrict execution to a test plan configuration. Repeatable.
          --skip-test-configuration <name>
                                      Exclude a test plan configuration. Repeatable.
          --metadata <key=value>     Attach metadata to the job summary. Repeatable.
          --label <value>            Shortcut for --metadata label=<value>.
          --help, -h                  Show this command help.
        """
    }

    private static func projectsHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] projects [--json]

        Options:
          --json      Print configured project profiles as JSON.
          --help, -h  Show this command help.
        """
    }

    private static func profileHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] profile show <name> [--json]
          \(executableName) [--state-root <path>] profile init --detect [options]

        Options:
          --name <name>                    Profile name for init. Defaults to repo directory name.
          --repo-root <path>               Repository root for init. Defaults to the current directory.
          --detect                         Detect the project/workspace and scheme.
          --scheme <name>                  Scheme to write when detection finds multiple schemes.
          --simulator-id <id>              Default simulator UDID to write.
          --managed-simulator-name <name>  Managed simulator name to write.
          --device-type <name-or-id>       Managed simulator device type to write.
          --runtime <name-or-id>           Managed simulator runtime to write.
          --force                          Overwrite an existing profile during init.
          --json                           Print the profile document as JSON.
          --help, -h                       Show this command help.
        """
    }

    private static func statusHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] status <job-id> [--watch] [--interval <seconds>] [--json]

        Options:
          --watch                 Poll until the job reaches a terminal state.
          --interval <seconds>    Watch polling interval. Default: 2.
          --json                  Print the job summary as JSON. With --watch, prints NDJSON summaries.
          --help, -h              Show this command help.
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

    private static func explainHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] explain <job-id> [--json]

        Options:
          --json      Print a bounded triage document as JSON.
          --help, -h  Show this command help.
        """
    }

    private static func logsHelp(executableName: String) -> String {
        """
        Usage:
          \(executableName) [--state-root <path>] logs <job-id> [--follow]

        Options:
          --follow    Stream appended combined log output until the job is terminal.
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
          --caches                Select XCSteward-owned cache/evidence files instead of jobs.
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

    private func handleProjects(arguments: [String], store: StateStore) throws -> Int32 {
        _ = store
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        guard arguments.isEmpty else {
            throw XCStewardError.usage("projects received unexpected arguments: \(arguments.joined(separator: " "))")
        }
        let document = try projectListDocument()
        if json {
            try writeSnakeCaseJSON(document)
        } else {
            for project in document.projects {
                print("\(project.name) \(project.loadStatus)")
            }
        }
        return 0
    }

    private func handleProfile(arguments: [String], store: StateStore) throws -> Int32 {
        _ = store
        var arguments = arguments
        guard let subcommand = arguments.first else {
            throw XCStewardError.usage("profile requires a subcommand: show or init")
        }
        arguments.removeFirst()
        switch subcommand {
        case "show":
            return try handleProfileShow(arguments: arguments)
        case "init":
            return try handleProfileInit(arguments: arguments)
        default:
            throw XCStewardError.usage("Unknown profile subcommand: \(subcommand)")
        }
    }

    private func handleProfileShow(arguments: [String]) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        guard let name = arguments.first else {
            throw XCStewardError.usage("profile show requires a profile name")
        }
        arguments.removeFirst()
        guard arguments.isEmpty else {
            throw XCStewardError.usage("profile show received unexpected arguments: \(arguments.joined(separator: " "))")
        }
        let profile = try ProfileLoader(environment: environment).loadProfile(named: name)
        let document = ProfileShowDocument(
            path: profilePath(for: profile.name).path,
            profile: profile
        )
        if json {
            try writeSnakeCaseJSON(document)
        } else {
            print("\(profile.name) \(profile.scheme) \(profile.repoRoot)")
        }
        return 0
    }

    private func handleProfileInit(arguments: [String]) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        let detect = removeFlag("--detect", from: &arguments)
        let force = removeFlag("--force", from: &arguments)
        let explicitName = try consumeOption("--name", from: &arguments)
        let repoRootValue = try consumeOption("--repo-root", from: &arguments)
        let explicitScheme = try consumeOption("--scheme", from: &arguments)
        let simulatorID = try consumeOption("--simulator-id", from: &arguments)
        let managedName = try consumeOption("--managed-simulator-name", from: &arguments)
        let deviceType = try consumeOption("--device-type", from: &arguments)
        let runtime = try consumeOption("--runtime", from: &arguments)
        guard arguments.isEmpty else {
            throw XCStewardError.usage("profile init received unexpected arguments: \(arguments.joined(separator: " "))")
        }
        guard detect else {
            throw XCStewardError.usage("profile init currently requires --detect")
        }
        guard simulatorID == nil || (managedName == nil && deviceType == nil && runtime == nil) else {
            throw XCStewardError.usage("profile init cannot combine --simulator-id with managed simulator options")
        }

        let repoRoot = absoluteURL(path: repoRootValue ?? ".")
        guard environment.fileSystem.fileExists(repoRoot) else {
            throw XCStewardError.invalidConfiguration("profile init repo root does not exist: \(repoRoot.path)")
        }
        let name = try profileName(explicitName: explicitName, repoRoot: repoRoot)
        let profileURL = profilePath(for: name)
        if environment.fileSystem.fileExists(profileURL), !force {
            throw XCStewardError.invalidConfiguration("Profile '\(name)' already exists at \(profileURL.path); pass --force to overwrite")
        }

        let detected = try detectProfile(repoRoot: repoRoot, explicitScheme: explicitScheme)
        let managedSimulator = try managedSimulatorOptions(
            profileName: name,
            managedName: managedName,
            deviceType: deviceType,
            runtime: runtime
        )
        let warnings = profileInitWarnings(simulatorID: simulatorID, managedSimulator: managedSimulator)
        try environment.fileSystem.writeData(
            Data(profileTOML(
                repoRoot: repoRoot,
                detected: detected,
                simulatorID: simulatorID,
                managedSimulator: managedSimulator
            ).utf8),
            to: profileURL
        )
        let profile = try ProfileLoader(environment: environment).loadProfile(named: name)
        let document = ProfileInitDocument(
            profilePath: profileURL.path,
            created: true,
            warnings: warnings,
            nextCommands: profileInitNextCommands(profileName: name, hasSimulatorAssignment: simulatorID != nil || managedSimulator != nil),
            profile: profile
        )
        if json {
            try writeSnakeCaseJSON(document)
        } else {
            print("Created \(name) at \(profileURL.path)")
            for warning in warnings {
                print("warning: \(warning)")
            }
        }
        return 0
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
        if !options.json {
            printSubmitContext(for: record)
        }

        if request.wait {
            do {
                try spawnWorkerIfNeeded(executableURL: workerExecutableURL)
                progress.emit("worker_ready", job: try store.fetchJob(id: jobID) ?? record)
            } catch {
                return try failJobAfterWorkerLaunchFailure(error, job: record, store: store, json: options.json, progress: progress)
            }
            let terminal = try waitForJob(
                id: jobID,
                store: store,
                timeout: options.waitTimeout,
                progress: progress,
                humanProgress: !options.json,
                workerExecutableURL: workerExecutableURL
            )
            try printJob(terminal, json: options.json)
            return exitCode(for: terminal.resultClass, state: terminal.state)
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
        let watch = removeFlag("--watch", from: &arguments)
        let intervalValue = try consumeOption("--interval", from: &arguments)
        if !watch, intervalValue != nil {
            throw XCStewardError.usage("status --interval requires --watch")
        }
        let interval = try intervalValue.map(parseWatchInterval(_:)) ?? 2
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
        if watch {
            return try watchStatus(id: jobID, initialJob: job, store: store, interval: interval, json: json)
        }
        try printJob(job, json: json)
        return exitCode(for: job.resultClass, state: job.state)
    }

    private func handleJobs(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        guard arguments.isEmpty else {
            throw XCStewardError.usage("jobs received unexpected arguments: \(arguments.joined(separator: " "))")
        }
        let jobs = try store.listJobs()
        if json {
            // Full JobSummary per job (same shape as `status --json`), so agents
            // get one consistent object everywhere. Bare array; each element
            // carries schema_version.
            let summaries = try jobs.map { try loadSummary(for: $0) }
            FileHandle.standardOutput.write(try jsonData(summaries))
        } else {
            for job in jobs {
                print("\(job.id) \(job.state.rawValue)")
            }
        }
        return 0
    }

    private func handleExplain(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let json = removeFlag("--json", from: &arguments)
        guard let jobID = arguments.first else {
            throw XCStewardError.usage("explain requires a job id")
        }
        arguments.removeFirst()
        guard arguments.isEmpty else {
            throw XCStewardError.usage("explain received unexpected arguments: \(arguments.joined(separator: " "))")
        }
        guard let job = try store.fetchJob(id: jobID) else {
            throw XCStewardError.notFound("Job \(jobID) not found")
        }
        let summary = try loadSummary(for: job)
        let document = explainDocument(for: summary)
        if json {
            try writeSnakeCaseJSON(document)
        } else {
            print("\(summary.jobID) \(summary.state.rawValue) \(summary.resultClass?.rawValue ?? "pending"): \(document.recommendedAction)")
            for failedTest in document.failedTests {
                print("failed test: \(failedTest.className).\(failedTest.name)")
            }
            for issue in document.buildIssues {
                print("\(issue.source):\(issue.lineNumber): \(issue.text)")
            }
        }
        return 0
    }

    private func handleLogs(arguments: [String], store: StateStore) throws -> Int32 {
        var arguments = arguments
        let follow = removeFlag("--follow", from: &arguments)
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
        if follow {
            try followLog(for: job, store: store, path: summary.artifacts.combinedLog)
            return 0
        }
        if let log = summary.artifacts.combinedLog {
            let url = URL(fileURLWithPath: log)
            guard environment.fileSystem.fileExists(url) else {
                print(missingCombinedLogMessage(for: job, path: log))
                return 0
            }
            let data = try environment.fileSystem.readData(from: url)
            FileHandle.standardOutput.write(data)
        } else {
            print(missingCombinedLogMessage(for: job, path: nil))
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
        let caches = removeFlag("--caches", from: &arguments)
        if apply && dryRunFlag {
            throw XCStewardError.usage("cleanup cannot combine --apply and --dry-run")
        }
        let olderThanValue = try consumeOption("--older-than", from: &arguments)
        let keepLastValue = try consumeOption("--keep-last", from: &arguments)
        let maxTotalBytesValue = try consumeOption("--max-total-size", from: &arguments)
        if caches && (olderThanValue != nil || keepLastValue != nil || maxTotalBytesValue != nil) {
            throw XCStewardError.usage("cleanup --caches cannot combine with job cleanup filters")
        }
        let olderThan = try olderThanValue
            .map(parseCleanupDuration(_:)) ?? (7 * 24 * 60 * 60)
        let keepLast = try keepLastValue
            .map { try parseNonNegativeInteger($0, option: "--keep-last") } ?? 20
        let maxTotalBytes = try maxTotalBytesValue
            .map(parseCleanupSize(_:))
        guard arguments.isEmpty else {
            throw XCStewardError.usage("cleanup received unexpected arguments: \(arguments.joined(separator: " "))")
        }

        let cleanupService = CleanupService(environment: environment)
        let report: CleanupReport
        if caches {
            report = try cleanupService.cleanupCaches(dryRun: !apply)
        } else {
            report = try cleanupService.cleanupTerminalJobs(
                store: store,
                olderThanSeconds: olderThan,
                keepLast: keepLast,
                maxTotalBytes: maxTotalBytes,
                dryRun: !apply
            )
        }
        if json {
            FileHandle.standardOutput.write(try jsonData(report))
        } else if caches, report.dryRun {
            print("Dry run: \(report.cacheCandidateCount) cache item(s) eligible for cleanup")
            for candidate in report.cacheCandidates {
                let bytes = candidate.bytes.map(String.init) ?? "unknown"
                print("\(candidate.kind) \(candidate.reason) \(bytes) \(candidate.path)")
            }
        } else if caches {
            print("Deleted \(report.cacheDeletedCount) cache item(s)")
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

    private func parseWatchInterval(_ value: String) throws -> TimeInterval {
        guard let parsed = TimeInterval(value), parsed > 0 else {
            throw XCStewardError.usage("status --interval must be greater than 0 seconds")
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
        return report.overallStatus == .fail ? ExitCode.doctorFailed : ExitCode.success
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
        progress: CLIProgressReporter,
        humanProgress: Bool,
        workerExecutableURL: URL?
    ) throws -> JobRecord {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSignature: String?
        var nextHeartbeat = environment.clock.now().addingTimeInterval(5)
        var lastHumanSignature: String?
        var nextHumanHeartbeat = environment.clock.now().addingTimeInterval(30)
        while Date() < deadline {
            try reconcileWorkerDuringWait(store: store, workerExecutableURL: workerExecutableURL)
            if let job = try store.fetchJob(id: id) {
                let now = environment.clock.now()
                if humanProgress {
                    let update = humanProgressUpdate(for: job, now: now)
                    if update.signature != lastHumanSignature || now >= nextHumanHeartbeat {
                        print(update.line)
                        lastHumanSignature = update.signature
                        nextHumanHeartbeat = now.addingTimeInterval(30)
                    }
                }
                let signature = [
                    job.state.rawValue,
                    job.resultClass?.rawValue ?? "",
                    job.processID.map(String.init) ?? "",
                    job.simulatorID ?? "",
                ].joined(separator: "|")
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

    private func watchStatus(
        id: String,
        initialJob: JobRecord,
        store: StateStore,
        interval: TimeInterval,
        json: Bool
    ) throws -> Int32 {
        var current = initialJob
        while true {
            if let refreshed = try store.fetchJob(id: id) {
                current = refreshed
            } else {
                throw XCStewardError.notFound("Job \(id) not found")
            }
            if json {
                try writeJSONLine(loadSummary(for: current))
            } else {
                let update = humanProgressUpdate(for: current, now: environment.clock.now())
                print(update.line)
            }
            if current.state.isTerminal {
                return exitCode(for: current.resultClass, state: current.state)
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    private func followLog(for job: JobRecord, store: StateStore, path: String?) throws {
        let logPath = path ?? combinedLogPath(for: job)
        if !environment.fileSystem.fileExists(URL(fileURLWithPath: logPath)) {
            print(missingCombinedLogMessage(for: job, path: logPath, following: true))
        }
        var offset = 0
        var current = job
        while true {
            offset = try writeNewLogData(path: logPath, offset: offset)
            if current.state.isTerminal {
                _ = try writeNewLogData(path: logPath, offset: offset)
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
            current = try store.fetchJob(id: job.id) ?? current
        }
    }

    private func writeNewLogData(path: String, offset: Int) throws -> Int {
        let url = URL(fileURLWithPath: path)
        guard environment.fileSystem.fileExists(url) else {
            return offset
        }
        let data = try environment.fileSystem.readData(from: url)
        var offset = min(offset, data.count)
        if data.count > offset {
            FileHandle.standardOutput.write(data.subdata(in: offset..<data.count))
            offset = data.count
        }
        return offset
    }

    private func printSubmitContext(for job: JobRecord) {
        print("Queued job \(job.id) (\(job.state.rawValue)).")
        print("Status: \(xcstewardCommand("status", job.id))")
        print("Watch:  \(xcstewardCommand("status", job.id, "--watch"))")
        print("Logs:   \(xcstewardCommand("logs", job.id))")
        print("Follow: \(xcstewardCommand("logs", job.id, "--follow"))")
        print("Job dir: \(job.jobDirectory)")
    }

    private func xcstewardCommand(_ arguments: String...) -> String {
        let root = shellWord(environment.paths.stateRoot.path)
        return (["xcsteward", "--state-root", root] + arguments.map(shellWord(_:))).joined(separator: " ")
    }

    private func humanProgressUpdate(for job: JobRecord, now: Date) -> HumanProgressUpdate {
        let summary = try? loadSummary(for: job)
        let artifacts = summary?.artifacts ?? JobSummaryFactory().fallbackSummary(job: job).artifacts
        let commandProgress = humanCommandProgress(path: artifacts.commandEvents)
        let elapsed = max(0, now.timeIntervalSince1970 - job.createdAt)
        var parts = ["\(job.state.rawValue) \(formatDuration(elapsed))"]
        if let simulatorID = job.simulatorID ?? summary?.simulatorID {
            parts.append("simulator \(simulatorID)")
        }
        if let activePhase = commandProgress.activePhase {
            parts.append(activePhase)
        }
        if let timestamp = commandProgress.lastEventTimestamp {
            let age = max(0, now.timeIntervalSince1970 - timestamp)
            parts.append("last event \(formatDuration(age)) ago")
        }
        if let combinedLog = artifacts.combinedLog {
            let logStatus = environment.fileSystem.fileExists(URL(fileURLWithPath: combinedLog))
                ? "log"
                : (job.state.isTerminal ? "log missing" : "log pending")
            parts.append("\(logStatus) \(combinedLog)")
        }
        if job.state.isTerminal, let summary {
            if let resultClass = summary.resultClass {
                parts.append("result \(resultClass.rawValue)")
            }
            parts.append(summaryLineOneLine(summary.summaryLine))
        }
        let signature = [
            job.state.rawValue,
            job.resultClass?.rawValue ?? "",
            job.simulatorID ?? summary?.simulatorID ?? "",
            commandProgress.activePhase ?? "",
            commandProgress.lastEventName ?? "",
            commandProgress.lastEventTimestamp.map { String($0) } ?? "",
            artifacts.combinedLog.map { environment.fileSystem.fileExists(URL(fileURLWithPath: $0)) ? "log" : "log-missing" } ?? "",
            summary?.summaryLine ?? "",
        ].joined(separator: "|")
        return HumanProgressUpdate(line: parts.joined(separator: " | "), signature: signature)
    }

    private func humanCommandProgress(path: String?) -> HumanCommandProgress {
        guard let path else {
            return HumanCommandProgress(activePhase: nil, lastEventTimestamp: nil, lastEventName: nil)
        }
        let url = URL(fileURLWithPath: path)
        guard environment.fileSystem.fileExists(url),
              let data = try? environment.fileSystem.readData(from: url),
              let text = String(data: data, encoding: .utf8) else {
            return HumanCommandProgress(activePhase: nil, lastEventTimestamp: nil, lastEventName: nil)
        }
        let decoder = JSONDecoder()
        var lastEvent: RunCommandEvent?
        var activeEvents: [String: RunCommandEvent] = [:]
        for line in text.split(separator: "\n") {
            guard let event = try? decoder.decode(RunCommandEvent.self, from: Data(line.utf8)) else {
                continue
            }
            lastEvent = event
            let key = "\(event.phase ?? "")|\(event.tool)|\(event.commandLine)"
            switch event.event {
            case "launching", "started":
                activeEvents[key] = event
            case "finished", "failed":
                activeEvents.removeValue(forKey: key)
            default:
                break
            }
        }
        let active = activeEvents.values.sorted { $0.timestamp < $1.timestamp }.last
        return HumanCommandProgress(
            activePhase: active?.phase ?? active?.tool,
            lastEventTimestamp: lastEvent?.timestamp,
            lastEventName: lastEvent?.event
        )
    }

    private func missingCombinedLogMessage(for job: JobRecord, path: String?, following: Bool = false) -> String {
        let location = path.map { " at \($0)" } ?? ""
        let prefix = following
            ? "Combined log is not available yet for job \(job.id)\(location); waiting."
            : "Combined log is not available yet for job \(job.id)\(location)."
        let state = "Current state: \(job.state.rawValue)."
        let context = job.state.isTerminal
            ? "The job is terminal, so inspect status, artifacts, and command events for pre-log failure evidence."
            : "The job may still be queued or in simulator/bootstrap setup before xcodebuild writes logs."
        return "\(prefix) \(state) \(context) Status: \(xcstewardCommand("status", job.id, "--watch"))"
    }

    private func combinedLogPath(for job: JobRecord) -> String {
        URL(fileURLWithPath: job.jobDirectory).appendingPathComponent("logs/combined.log").path
    }

    private func summaryLineOneLine(_ text: String) -> String {
        let compact = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compact.count > 240 else {
            return compact
        }
        return "\(compact.prefix(240))..."
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 {
            return "\(minutes)m\(String(format: "%02d", seconds))s"
        }
        let hours = minutes / 60
        return "\(hours)h\(String(format: "%02d", minutes % 60))m"
    }

    private func writeJSONLine<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func reconcileWorkerDuringWait(store: StateStore, workerExecutableURL: URL?) throws {
        let recoveredStaleWorker = try store.recoverStaleLeaseIfNeeded()
        let recoveredUnownedJobs = try store.recoverUnownedRunningJobs()
        _ = try store.recoverStaleSimulatorLeases()
        guard recoveredStaleWorker || recoveredUnownedJobs > 0 else {
            return
        }
        if try store.hasQueuedJobs() {
            try spawnWorkerIfNeeded(executableURL: workerExecutableURL)
        }
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
        return ExitCode.infraFailure
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

    private func explainDocument(for summary: JobSummary) -> ExplainDocument {
        var warnings: [String] = []
        let failedTests = failedTests(from: summary.artifacts.junit, warnings: &warnings)
        let buildIssues = buildIssues(from: summary.artifacts.buildLog, warnings: &warnings)
        let logExcerpts = logExcerpts(from: summary.artifacts, warnings: &warnings)
        let retryPolicy = explainRetryPolicy(for: summary)
        return ExplainDocument(
            jobID: summary.jobID,
            project: summary.project,
            state: summary.state,
            resultClass: summary.resultClass,
            exitCode: summary.exitCode,
            summaryLine: summary.summaryLine,
            retryPolicy: retryPolicy,
            recommendedAction: recommendedAction(for: summary, retryPolicy: retryPolicy),
            artifacts: summary.artifacts,
            failedTests: failedTests,
            buildIssues: buildIssues,
            logExcerpts: logExcerpts,
            warnings: warnings,
            summary: summary
        )
    }

    private func explainRetryPolicy(for summary: JobSummary) -> ExplainRetryPolicy {
        guard summary.state.isTerminal else {
            return ExplainRetryPolicy(
                autoRetry: false,
                maxAutoRetries: 0,
                reason: "Job has not reached a terminal state."
            )
        }
        switch summary.resultClass {
        case .success:
            return ExplainRetryPolicy(autoRetry: false, maxAutoRetries: 0, reason: "Job succeeded.")
        case .buildFailure, .testFailure:
            return ExplainRetryPolicy(autoRetry: false, maxAutoRetries: 0, reason: "Product or test failure; inspect evidence before changing code.")
        case .buildTimeout, .testTimeout:
            return ExplainRetryPolicy(autoRetry: true, maxAutoRetries: 1, reason: "Timeouts may be retryable once, then should be investigated as flakiness or capacity trouble.")
        case .runnerBootstrapFailure:
            if SimulatorBootstrapFailureDiagnosis.matches(summary.summaryLine) {
                return ExplainRetryPolicy(autoRetry: true, maxAutoRetries: 1, reason: "Environment failure before XCTest attached; remediate simulator bootstrap state and retry once.")
            }
            return ExplainRetryPolicy(autoRetry: true, maxAutoRetries: 1, reason: "Infrastructure or artifact failure; run doctor and inspect evidence before retrying.")
        case .artifactFailure:
            return ExplainRetryPolicy(autoRetry: true, maxAutoRetries: 1, reason: "Infrastructure or artifact failure; run doctor and inspect evidence before retrying.")
        case .canceled:
            return ExplainRetryPolicy(autoRetry: false, maxAutoRetries: 0, reason: "Job was canceled; retry only if the cancellation was incidental.")
        case .internalError, .unsupportedDestination:
            return ExplainRetryPolicy(autoRetry: false, maxAutoRetries: 0, reason: "XCSteward or profile configuration issue; inspect diagnostics before retrying.")
        case nil:
            return ExplainRetryPolicy(autoRetry: false, maxAutoRetries: 0, reason: "Terminal job has no result class; report with full summary and artifacts.")
        }
    }

    private func recommendedAction(for summary: JobSummary, retryPolicy: ExplainRetryPolicy) -> String {
        guard summary.state.isTerminal else {
            return "Wait for the job to finish, then run explain again."
        }
        switch summary.resultClass {
        case .success:
            return "Report success and include useful artifact paths if the user needs evidence."
        case .buildFailure:
            return "Inspect build issues and build log; do not blind-retry."
        case .testFailure:
            return "Inspect failed tests, JUnit, .xcresult, and test log; do not blind-retry."
        case .buildTimeout, .testTimeout:
            return "Retry at most once, then investigate timeout evidence and host capacity."
        case .runnerBootstrapFailure:
            if SimulatorBootstrapFailureDiagnosis.matches(summary.summaryLine) {
                return "\(SimulatorBootstrapFailureDiagnosis.preXCTestMessage) \(SimulatorBootstrapFailureDiagnosis.remediationHint(simulatorID: summary.simulatorID))"
            }
            return "Inspect artifacts, run xcsteward doctor --json, fix environment issues, then retry if appropriate."
        case .artifactFailure:
            return "Inspect artifacts, run xcsteward doctor --json, fix environment issues, then retry if appropriate."
        case .canceled:
            return "Report cancellation; submit a fresh job only if cancellation was incidental."
        case .internalError, .unsupportedDestination:
            return "Report with artifacts and check the XCSteward profile, destination, or configuration."
        case nil:
            return retryPolicy.reason
        }
    }

    private func failedTests(from junitPath: String?, warnings: inout [String]) -> [ExplainFailedTest] {
        guard let text = artifactText(path: junitPath, source: "junit", warnings: &warnings) else {
            return []
        }
        return JUnitFailureExtractor.failures(from: text)
    }

    private func buildIssues(from buildLogPath: String?, warnings: inout [String]) -> [ExplainIssue] {
        guard let text = artifactText(path: buildLogPath, source: "build_log", warnings: &warnings),
              let buildLogPath else {
            return []
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line -> ExplainIssue? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isBuildIssueLine(trimmed) else {
                    return nil
                }
                return ExplainIssue(
                    source: "build_log",
                    path: buildLogPath,
                    lineNumber: index + 1,
                    text: trimmed
                )
            }
            .prefix(20)
            .map { $0 }
    }

    private func isBuildIssueLine(_ line: String) -> Bool {
        guard !line.isEmpty else {
            return false
        }
        return line.localizedCaseInsensitiveContains("error:")
            || line.localizedCaseInsensitiveContains("build failed")
            || line.localizedCaseInsensitiveContains("unable to")
    }

    private func logExcerpts(from artifacts: JobArtifacts, warnings: inout [String]) -> [ExplainLogExcerpt] {
        [
            ("combined_log", artifacts.combinedLog),
            ("build_log", artifacts.buildLog),
            ("test_log", artifacts.testLog),
        ].compactMap { source, path in
            logExcerpt(source: source, path: path, warnings: &warnings)
        }
    }

    private func logExcerpt(source: String, path: String?, warnings: inout [String]) -> ExplainLogExcerpt? {
        guard let text = artifactText(path: path, source: source, warnings: &warnings),
              let path else {
            return nil
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let tail = lines.suffix(40).joined(separator: "\n")
        return ExplainLogExcerpt(
            source: source,
            path: path,
            lineCount: lines.count,
            excerpt: String(tail.suffix(8_000))
        )
    }

    private func artifactText(path: String?, source: String, warnings: inout [String]) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        guard environment.fileSystem.fileExists(url) else {
            warnings.append("\(source) path does not exist: \(path)")
            return nil
        }
        do {
            let data = try environment.fileSystem.readData(from: url)
            guard let text = String(data: data, encoding: .utf8) else {
                warnings.append("\(source) is not valid UTF-8: \(path)")
                return nil
            }
            return text
        } catch {
            warnings.append("Unable to read \(source) at \(path): \(error)")
            return nil
        }
    }

    private func projectListDocument() throws -> ProjectListDocument {
        let loader = ProfileLoader(environment: environment)
        let profileURLs = try environment.fileSystem.contentsOfDirectory(environment.paths.projectsRoot)
            .filter { $0.pathExtension == "toml" && environment.fileSystem.isRegularFile($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let projects = profileURLs.map { url in
            projectReferenceDocument(url: url, loader: loader)
        }
        return ProjectListDocument(
            stateRoot: environment.paths.stateRoot.path,
            projectsRoot: environment.paths.projectsRoot.path,
            projects: projects
        )
    }

    private func projectReferenceDocument(url: URL, loader: ProfileLoader) -> ProjectReferenceDocument {
        let name = url.deletingPathExtension().lastPathComponent
        do {
            let profile = try loader.loadProfile(named: name)
            return ProjectReferenceDocument(
                name: name,
                path: url.path,
                loadStatus: "valid",
                errorCode: nil,
                errorMessage: nil,
                repoRoot: profile.repoRoot,
                projectPath: profile.projectPath,
                workspacePath: profile.workspacePath,
                scheme: profile.scheme
            )
        } catch {
            return ProjectReferenceDocument(
                name: name,
                path: url.path,
                loadStatus: "invalid",
                errorCode: errorCode(for: error),
                errorMessage: String(describing: error),
                repoRoot: nil,
                projectPath: nil,
                workspacePath: nil,
                scheme: nil
            )
        }
    }

    private func profilePath(for name: String) -> URL {
        environment.paths.projectsRoot.appendingPathComponent("\(name).toml")
    }

    private func absoluteURL(path: String) -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL
    }

    private func profileName(explicitName: String?, repoRoot: URL) throws -> String {
        let name = (explicitName ?? repoRoot.lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else {
            throw XCStewardError.usage("profile init requires a non-empty profile name")
        }
        guard name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil else {
            throw XCStewardError.usage("profile init profile name must not contain path separators")
        }
        return name
    }

    private func detectProfile(repoRoot: URL, explicitScheme: String?) throws -> DetectedProfileTarget {
        let detected = try detectBuildContainer(repoRoot: repoRoot)
        let containerURL = repoRoot.appendingPathComponent(detected.containerPath)
        let result = try environment.toolRunner.run(
            tool: "xcodebuild",
            arguments: [detected.containerKey == "workspace_path" ? "-workspace" : "-project", containerURL.path, "-list", "-json"],
            environment: environment.processInfo.environment,
            workingDirectory: repoRoot,
            timeout: 60
        )
        guard result.exitCode == 0, !result.timedOut else {
            throw XCStewardError.commandFailed("profile init --detect could not list Xcode schemes for \(containerURL.path): \(result.output)")
        }
        let schemes = availableSchemes(from: result.output)
        guard !schemes.isEmpty else {
            throw XCStewardError.invalidConfiguration("profile init --detect found no shared schemes in \(containerURL.path)")
        }
        let scheme = try chooseScheme(
            availableSchemes: schemes,
            explicitScheme: explicitScheme,
            preferredName: containerURL.deletingPathExtension().lastPathComponent
        )
        return DetectedProfileTarget(
            containerKey: detected.containerKey,
            containerPath: detected.containerPath,
            scheme: scheme,
            availableSchemes: schemes
        )
    }

    private func detectBuildContainer(repoRoot: URL) throws -> (containerKey: String, containerPath: String) {
        let entries = try environment.fileSystem.contentsOfDirectory(repoRoot)
        let workspaces = entries
            .filter { $0.pathExtension == "xcworkspace" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let projects = entries
            .filter { $0.pathExtension == "xcodeproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        if workspaces.count == 1 {
            return ("workspace_path", workspaces[0].lastPathComponent)
        }
        if workspaces.count > 1 {
            throw XCStewardError.invalidConfiguration("profile init --detect found multiple workspaces; pass a narrower repo root")
        }
        if projects.count == 1 {
            return ("project_path", projects[0].lastPathComponent)
        }
        if projects.count > 1 {
            throw XCStewardError.invalidConfiguration("profile init --detect found multiple Xcode projects; pass a narrower repo root")
        }
        throw XCStewardError.invalidConfiguration("profile init --detect found no .xcworkspace or .xcodeproj at \(repoRoot.path)")
    }

    private func chooseScheme(
        availableSchemes: [String],
        explicitScheme: String?,
        preferredName: String
    ) throws -> String {
        if let explicitScheme {
            guard availableSchemes.contains(explicitScheme) else {
                throw XCStewardError.invalidConfiguration(
                    "profile init --scheme '\(explicitScheme)' was not found; available schemes: \(availableSchemes.joined(separator: ", "))"
                )
            }
            return explicitScheme
        }
        if availableSchemes.count == 1 {
            return availableSchemes[0]
        }
        if availableSchemes.contains(preferredName) {
            return preferredName
        }
        throw XCStewardError.invalidConfiguration(
            "profile init --detect found multiple schemes; pass --scheme. Available schemes: \(availableSchemes.joined(separator: ", "))"
        )
    }

    private func availableSchemes(from output: String) -> [String] {
        guard let json = jsonObject(from: output) else {
            return output
                .split(separator: "\n")
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\","))
                }
                .filter { !$0.isEmpty }
        }
        if let project = json["project"] as? [String: Any],
           let schemes = project["schemes"] as? [String] {
            return schemes
        }
        if let workspace = json["workspace"] as? [String: Any],
           let schemes = workspace["schemes"] as? [String] {
            return schemes
        }
        return []
    }

    private func jsonObject(from output: String) -> [String: Any]? {
        func parse(_ text: String) -> [String: Any]? {
            guard let data = text.data(using: .utf8) else {
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        if let json = parse(output) {
            return json
        }
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return parse(String(output[start...end]))
    }

    private func managedSimulatorOptions(
        profileName: String,
        managedName: String?,
        deviceType: String?,
        runtime: String?
    ) throws -> ManagedSimulatorInitOptions? {
        guard managedName != nil || deviceType != nil || runtime != nil else {
            return nil
        }
        guard let deviceType, let runtime else {
            throw XCStewardError.usage("profile init managed simulator options require --device-type and --runtime")
        }
        return ManagedSimulatorInitOptions(
            name: managedName ?? "XCSteward \(profileName) iPhone",
            deviceType: deviceType,
            runtime: runtime
        )
    }

    private func profileInitWarnings(
        simulatorID: String?,
        managedSimulator: ManagedSimulatorInitOptions?
    ) -> [String] {
        if simulatorID == nil && managedSimulator == nil {
            return ["No simulator assignment was written; add default_simulator_id or managed_simulator settings before running submit."]
        }
        return []
    }

    private func profileInitNextCommands(profileName: String, hasSimulatorAssignment: Bool) -> [String] {
        let project = shellWord(profileName)
        var commands = [
            "xcsteward profile show \(project) --json",
            "xcsteward doctor --project \(project) --json --progress",
        ]
        if hasSimulatorAssignment {
            commands.append("xcsteward submit --project \(project) --wait --json --progress")
        } else {
            commands.append("xcsteward submit --project \(project) --simulator-id <SIMULATOR-UDID> --wait --json --progress")
        }
        return commands
    }

    private func shellWord(_ value: String) -> String {
        guard value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"\\$`"))) != nil else {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func profileTOML(
        repoRoot: URL,
        detected: DetectedProfileTarget,
        simulatorID: String?,
        managedSimulator: ManagedSimulatorInitOptions?
    ) -> String {
        var lines = [
            "repo_root = \(tomlString(repoRoot.path))",
            "\(detected.containerKey) = \(tomlString(detected.containerPath))",
            "scheme = \(tomlString(detected.scheme))",
        ]
        if let simulatorID {
            lines.append("default_simulator_id = \(tomlString(simulatorID))")
        }
        if let managedSimulator {
            lines.append("")
            lines.append("[managed_simulator]")
            lines.append("name = \(tomlString(managedSimulator.name))")
            lines.append("device_type = \(tomlString(managedSimulator.deviceType))")
            lines.append("runtime = \(tomlString(managedSimulator.runtime))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func writeSnakeCaseJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        FileHandle.standardOutput.write(try encoder.encode(value))
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

private final class JUnitFailureExtractor: NSObject, XMLParserDelegate {
    private var failures: [ExplainFailedTest] = []
    private var currentClassName: String?
    private var currentName: String?
    private var currentFailureKind: String?
    private var currentFailureMessage: String?
    private var currentFailureText = ""

    static func failures(from text: String) -> [ExplainFailedTest] {
        let extractor = JUnitFailureExtractor()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = extractor
        _ = parser.parse()
        return extractor.failures
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "testcase":
            currentClassName = attributeDict["classname"] ?? "XCSteward"
            currentName = attributeDict["name"] ?? "unknown"
        case "failure", "error":
            guard currentName != nil else {
                return
            }
            currentFailureKind = elementName
            currentFailureMessage = attributeDict["message"]
            currentFailureText = ""
        default:
            return
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentFailureKind != nil {
            currentFailureText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "failure", "error":
            guard let currentFailureKind,
                  let currentName else {
                return
            }
            let text = currentFailureText.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = currentFailureMessage ?? (text.isEmpty ? nil : text)
            failures.append(ExplainFailedTest(
                className: currentClassName ?? "XCSteward",
                name: currentName,
                failureKind: currentFailureKind,
                message: message
            ))
            self.currentFailureKind = nil
            currentFailureMessage = nil
            currentFailureText = ""
        case "testcase":
            currentClassName = nil
            currentName = nil
            currentFailureKind = nil
            currentFailureMessage = nil
            currentFailureText = ""
        default:
            return
        }
    }
}
