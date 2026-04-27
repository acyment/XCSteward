import Foundation

public enum JobState: String, Codable {
    case queued
    case running
    case succeeded
    case failed
    case canceled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .queued, .running:
            return false
        case .succeeded, .failed, .canceled, .interrupted:
            return true
        }
    }
}

public enum ResultClass: String, Codable {
    case success
    case buildFailure = "build_failure"
    case testFailure = "test_failure"
    case testTimeout = "test_timeout"
    case runnerBootstrapFailure = "runner_bootstrap_failure"
    case artifactFailure = "artifact_failure"
    case canceled
    case internalError = "internal_error"
}

public struct Timeouts: Codable {
    public var boot: TimeInterval
    public var build: TimeInterval
    public var test: TimeInterval

    public init(boot: TimeInterval = 30, build: TimeInterval = 600, test: TimeInterval = 600) {
        self.boot = boot
        self.build = build
        self.test = test
    }
}

public struct ManagedSimulator: Codable {
    public var name: String
    public var deviceType: String
    public var runtime: String
}

public struct ProjectProfile: Codable {
    public var name: String
    public var repoRoot: String
    public var projectPath: String?
    public var workspacePath: String?
    public var scheme: String
    public var defaultSimulatorID: String?
    public var managedSimulator: ManagedSimulator?
    public var defaultTestPlan: String?
    public var allowedSimulatorIDs: [String]
    public var env: [String: String]
    public var timeouts: Timeouts
    public var resetPolicy: String?

    public var workingDirectory: URL {
        URL(fileURLWithPath: repoRoot)
    }
}

public struct JobRequest: Codable {
    public var project: String
    public var testPlan: String?
    public var onlyTesting: [String]
    public var simulatorID: String?
    public var metadata: [String: String]
    public var wait: Bool
}

public struct JobArtifacts: Codable {
    public var xcresult: String?
    public var combinedLog: String?
    public var buildLog: String?
    public var testLog: String?
    public var derivedData: String?
    public var diagnostics: String?
}

public struct JobCounts: Codable {
    public var testsRun: Int
    public var testsFailed: Int
    public var testsSkipped: Int
}

public struct JobSummary: Codable {
    public var jobID: String
    public var project: String
    public var state: JobState
    public var resultClass: ResultClass?
    public var exitCode: Int32?
    public var submittedAt: Double
    public var startedAt: Double?
    public var finishedAt: Double?
    public var durationSeconds: Double?
    public var testPlan: String?
    public var onlyTesting: [String]
    public var simulatorID: String?
    public var counts: JobCounts?
    public var artifacts: JobArtifacts
    public var summaryLine: String
    public var metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case project
        case state
        case resultClass = "result_class"
        case exitCode = "exit_code"
        case submittedAt = "submitted_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case durationSeconds = "duration_seconds"
        case testPlan = "test_plan"
        case onlyTesting = "only_testing"
        case simulatorID = "simulator_id"
        case counts
        case artifacts
        case summaryLine = "summary_line"
        case metadata
    }
}

public struct JobRecord {
    public var id: String
    public var project: String
    public var state: JobState
    public var resultClass: ResultClass?
    public var request: JobRequest
    public var summary: JobSummary?
    public var jobDirectory: String
    public var createdAt: Double
    public var startedAt: Double?
    public var finishedAt: Double?
    public var processID: Int32?
    public var simulatorID: String?
    public var cancelRequested: Bool
}

public struct WorkerLease {
    public var workerID: String
    public var pid: Int32
    public var heartbeat: Double
    public var jobID: String?
}

public enum DoctorStatus: String, Codable {
    case pass
    case warn
    case fail
}

public struct DoctorCheck: Codable {
    public var id: String
    public var status: DoctorStatus
    public var message: String
    public var autoFixable: Bool
    public var fixed: Bool
    public var manualAction: String?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case message
        case autoFixable = "auto_fixable"
        case fixed
        case manualAction = "manual_action"
    }
}

public struct DoctorReport: Codable {
    public var overallStatus: DoctorStatus
    public var checks: [DoctorCheck]
    public var profilesChecked: [String]

    enum CodingKeys: String, CodingKey {
        case overallStatus = "overall_status"
        case checks
        case profilesChecked = "profiles_checked"
    }
}
