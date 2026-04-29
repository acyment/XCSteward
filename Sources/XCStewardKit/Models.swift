import Foundation

public enum JobState: String, Codable, Sendable {
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

public enum ResultClass: String, Codable, Sendable {
    case success
    case buildFailure = "build_failure"
    case testFailure = "test_failure"
    case testTimeout = "test_timeout"
    case runnerBootstrapFailure = "runner_bootstrap_failure"
    case artifactFailure = "artifact_failure"
    case canceled
    case internalError = "internal_error"

    public var isInfrastructureFailure: Bool {
        switch self {
        case .runnerBootstrapFailure, .artifactFailure:
            return true
        case .success, .buildFailure, .testFailure, .testTimeout, .canceled, .internalError:
            return false
        }
    }
}

public struct Timeouts: Codable, Sendable {
    public var boot: TimeInterval
    public var build: TimeInterval
    public var test: TimeInterval

    public init(boot: TimeInterval = 30, build: TimeInterval = 600, test: TimeInterval = 600) {
        self.boot = boot
        self.build = build
        self.test = test
    }
}

public struct ManagedSimulator: Codable, Sendable {
    public var name: String
    public var deviceType: String
    public var runtime: String
    public var cloneForShards: Bool
}

public enum ParallelMode: String, Codable, Sendable {
    case hybrid
    case manualShards = "manual-shards"
    case xcodeManaged = "xcode-managed"
    case serial
}

public struct ParallelSettings: Codable, Sendable {
    public var mode: ParallelMode
    public var maxWorkers: Int
    public var exactWorkers: Bool
    public var shardCount: Int

    public init(mode: ParallelMode = .xcodeManaged, maxWorkers: Int = 1, exactWorkers: Bool = false, shardCount: Int = 1) {
        self.mode = mode
        self.maxWorkers = maxWorkers
        self.exactWorkers = exactWorkers
        self.shardCount = shardCount
    }
}

public struct PortRangeSettings: Codable, Sendable {
    public var base: Int
    public var count: Int
    public var stride: Int

    public init(base: Int, count: Int = 16, stride: Int = 100) {
        self.base = base
        self.count = count
        self.stride = stride
    }
}

public struct XCTestTimeoutSettings: Codable, Sendable {
    public var enabled: Bool
    public var defaultExecutionTimeAllowance: Int
    public var maximumExecutionTimeAllowance: Int

    public init(
        enabled: Bool = true,
        defaultExecutionTimeAllowance: Int = 120,
        maximumExecutionTimeAllowance: Int = 600
    ) {
        self.enabled = enabled
        self.defaultExecutionTimeAllowance = defaultExecutionTimeAllowance
        self.maximumExecutionTimeAllowance = maximumExecutionTimeAllowance
    }
}

public struct XCTestRetrySettings: Codable, Sendable {
    public var enabled: Bool
    public var iterations: Int
    public var retryTestsOnFailure: Bool
    public var runTestsUntilFailure: Bool
    public var relaunchBetweenIterations: Bool?

    public init(
        enabled: Bool = false,
        iterations: Int = 1,
        retryTestsOnFailure: Bool = true,
        runTestsUntilFailure: Bool = false,
        relaunchBetweenIterations: Bool? = nil
    ) {
        self.enabled = enabled
        self.iterations = iterations
        self.retryTestsOnFailure = retryTestsOnFailure
        self.runTestsUntilFailure = runTestsUntilFailure
        self.relaunchBetweenIterations = relaunchBetweenIterations
    }
}

public enum XCTestDiagnosticCollectionMode: String, Codable, Sendable {
    case never
    case onFailure = "on-failure"
}

public struct XCTestDiagnosticSettings: Codable, Sendable {
    public var collect: XCTestDiagnosticCollectionMode?

    public init(collect: XCTestDiagnosticCollectionMode? = nil) {
        self.collect = collect
    }
}

public struct XcodeDestinationSettings: Codable, Sendable {
    public var timeout: Int?

    public init(timeout: Int? = nil) {
        self.timeout = timeout
    }
}

public struct CodeCoverageSettings: Codable, Sendable {
    public var enabled: Bool?

    public init(enabled: Bool? = nil) {
        self.enabled = enabled
    }
}

public struct ResultStreamSettings: Codable, Sendable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}

public struct ResultBundleSettings: Codable, Sendable {
    public var version: Int?

    public init(version: Int? = nil) {
        self.version = version
    }
}

public struct TestProductsSettings: Codable, Sendable {
    public var enabled: Bool
    public var useForTesting: Bool

    public init(enabled: Bool = false, useForTesting: Bool = false) {
        self.enabled = enabled
        self.useForTesting = useForTesting
    }

    public var materializeDuringBuild: Bool {
        enabled || useForTesting
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case useForTesting = "use_for_testing"
    }
}

public enum SimulatorPrivacyAction: String, Codable, Sendable {
    case grant
    case revoke
    case reset
}

public struct SimulatorPrivacyPermission: Codable, Sendable {
    public var action: SimulatorPrivacyAction
    public var service: String
    public var bundleIdentifier: String?

    public init(action: SimulatorPrivacyAction, service: String, bundleIdentifier: String? = nil) {
        self.action = action
        self.service = service
        self.bundleIdentifier = bundleIdentifier
    }

    enum CodingKeys: String, CodingKey {
        case action
        case service
        case bundleIdentifier = "bundle_identifier"
    }
}

public struct SimulatorPrivacySettings: Codable, Sendable {
    public var permissions: [SimulatorPrivacyPermission]

    public init(permissions: [SimulatorPrivacyPermission] = []) {
        self.permissions = permissions
    }

    public var isEmpty: Bool {
        permissions.isEmpty
    }
}

public struct ProjectProfile: Codable, Sendable {
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
    public var parallel: ParallelSettings
    public var ports: PortRangeSettings?
    public var xctestTimeouts: XCTestTimeoutSettings
    public var xctestRetries: XCTestRetrySettings
    public var xctestDiagnostics: XCTestDiagnosticSettings
    public var destination: XcodeDestinationSettings
    public var coverage: CodeCoverageSettings
    public var resultStream: ResultStreamSettings
    public var resultBundle: ResultBundleSettings
    public var testProducts: TestProductsSettings
    public var privacy: SimulatorPrivacySettings

    public var workingDirectory: URL {
        URL(fileURLWithPath: repoRoot)
    }
}

public struct JobRequest: Codable, Sendable {
    public var project: String
    public var testPlan: String?
    public var onlyTesting: [String]
    public var skipTesting: [String]
    public var onlyTestConfigurations: [String]
    public var skipTestConfigurations: [String]
    public var simulatorID: String?
    public var metadata: [String: String]
    public var wait: Bool

    public init(
        project: String,
        testPlan: String?,
        onlyTesting: [String],
        skipTesting: [String] = [],
        onlyTestConfigurations: [String] = [],
        skipTestConfigurations: [String] = [],
        simulatorID: String?,
        metadata: [String: String],
        wait: Bool
    ) {
        self.project = project
        self.testPlan = testPlan
        self.onlyTesting = onlyTesting
        self.skipTesting = skipTesting
        self.onlyTestConfigurations = onlyTestConfigurations
        self.skipTestConfigurations = skipTestConfigurations
        self.simulatorID = simulatorID
        self.metadata = metadata
        self.wait = wait
    }

    enum CodingKeys: String, CodingKey {
        case project
        case testPlan
        case onlyTesting
        case skipTesting
        case onlyTestConfigurations
        case skipTestConfigurations
        case simulatorID
        case metadata
        case wait
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.project = try container.decode(String.self, forKey: .project)
        self.testPlan = try container.decodeIfPresent(String.self, forKey: .testPlan)
        self.onlyTesting = try container.decodeIfPresent([String].self, forKey: .onlyTesting) ?? []
        self.skipTesting = try container.decodeIfPresent([String].self, forKey: .skipTesting) ?? []
        self.onlyTestConfigurations = try container.decodeIfPresent([String].self, forKey: .onlyTestConfigurations) ?? []
        self.skipTestConfigurations = try container.decodeIfPresent([String].self, forKey: .skipTestConfigurations) ?? []
        self.simulatorID = try container.decodeIfPresent(String.self, forKey: .simulatorID)
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        self.wait = try container.decodeIfPresent(Bool.self, forKey: .wait) ?? false
    }
}

public struct JobArtifacts: Codable, Sendable {
    public var xcresult: String?
    public var combinedLog: String?
    public var buildLog: String?
    public var testLog: String?
    public var derivedData: String?
    public var diagnostics: String?
    public var junit: String?
}

public struct JobCounts: Codable, Sendable {
    public var testsRun: Int
    public var testsFailed: Int
    public var testsSkipped: Int
}

struct TestTimingSample: Sendable {
    var identifier: String
    var durationSeconds: Double
}

public struct JobSummary: Codable, Sendable {
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

public struct JobRecord: Sendable {
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

public struct WorkerLease: Sendable {
    public var workerID: String
    public var pid: Int32
    public var heartbeat: Double
    public var jobID: String?
}

public struct SimulatorLease: Sendable {
    public var simulatorID: String
    public var jobID: String
    public var pid: Int32
    public var acquiredAt: Double
    public var heartbeat: Double
}

public enum DoctorStatus: String, Codable, Sendable {
    case pass
    case warn
    case fail
}

public struct DoctorCheck: Codable, Sendable {
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

public struct DoctorReport: Codable, Sendable {
    public var overallStatus: DoctorStatus
    public var checks: [DoctorCheck]
    public var profilesChecked: [String]

    enum CodingKeys: String, CodingKey {
        case overallStatus = "overall_status"
        case checks
        case profilesChecked = "profiles_checked"
    }
}
