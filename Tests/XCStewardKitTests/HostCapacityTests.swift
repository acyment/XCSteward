import Darwin
import Foundation
import XCTest
@testable import XCStewardKit

final class HostCapacityTests: XCTestCase {
    func testRecoveredInfrastructureEventsConstrainConcurrentDispatch() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: [
                "XCSTEWARD_RECENT_INFRA_FAILURE_LIMIT": "1",
                "XCSTEWARD_RECENT_INFRA_FAILURE_WINDOW_SECONDS": "600",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ])
        )
        let store = try StateStore(environment: environment)
        try store.recordInfrastructureEvent(
            jobID: "job-1",
            simulatorID: "SIM-123",
            resultClass: .runnerBootstrapFailure,
            message: "Recovered shard retry"
        )

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3), 1)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["configured_max_jobs"] as? Int, 3)
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 1)
        XCTAssertEqual(health["recent_infrastructure_failures"] as? Int, 1)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("recent_infrastructure_failures=1") == true)
    }

    func testNonInfrastructureEventsDoNotConstrainConcurrentDispatch() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: [
                "XCSTEWARD_RECENT_INFRA_FAILURE_LIMIT": "1",
                "XCSTEWARD_RECENT_INFRA_FAILURE_WINDOW_SECONDS": "600",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ])
        )
        let store = try StateStore(environment: environment)
        try store.recordInfrastructureEvent(
            jobID: "job-1",
            simulatorID: "SIM-123",
            resultClass: .testFailure,
            message: "Assertion failure"
        )

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3), 3)
        XCTAssertEqual(try store.countRecentInfrastructureFailures(since: 0), 0)
    }

    func testInfrastructureDrainModeStopsDispatchWhenThresholdIsReached() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: [
                "XCSTEWARD_RECENT_INFRA_FAILURE_LIMIT": "3",
                "XCSTEWARD_INFRA_FAILURE_DRAIN_LIMIT": "1",
                "XCSTEWARD_RECENT_INFRA_FAILURE_WINDOW_SECONDS": "600",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ])
        )
        let store = try StateStore(environment: environment)
        try store.recordInfrastructureEvent(
            jobID: "job-1",
            simulatorID: "SIM-123",
            resultClass: .artifactFailure,
            message: "Recovered artifact failure"
        )

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3), 0)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["configured_max_jobs"] as? Int, 3)
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 0)
        XCTAssertEqual(health["recent_infrastructure_failures"] as? Int, 1)
        XCTAssertEqual(health["infrastructure_failure_drain_limit"] as? Int, 1)
        XCTAssertEqual(health["draining"] as? Bool, true)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("drain_recent_infrastructure_failures=1") == true)
    }

    func testActiveSimulatorLeaseBudgetCanStopNewDispatch() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: [
                "XCSTEWARD_MAX_ACTIVE_SIMULATOR_LEASES": "1",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ])
        )
        let store = try StateStore(environment: environment)
        XCTAssertTrue(try store.acquireSimulatorLease(simulatorID: "SIM-123", jobID: "active-job", pid: getpid()))

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3, activeJobCount: 0), 0)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["configured_max_jobs"] as? Int, 3)
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 0)
        XCTAssertEqual(health["active_simulator_lease_count"] as? Int, 1)
        XCTAssertEqual(health["max_active_simulator_leases"] as? Int, 1)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("active_simulator_leases=1/1") == true)
    }

    func testActiveJobCountReservesSimulatorLeaseBudgetBeforeLeaseAppears() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: [
                "XCSTEWARD_MAX_ACTIVE_SIMULATOR_LEASES": "1",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ])
        )
        let store = try StateStore(environment: environment)

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3, activeJobCount: 1), 1)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 1)
        XCTAssertEqual(health["active_simulator_lease_count"] as? Int, 0)
        XCTAssertEqual(health["max_active_simulator_leases"] as? Int, 1)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("active_simulator_leases=0/1") == true)
    }

    func testLoadAverageCanConstrainConcurrentDispatch() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: [
                "XCSTEWARD_LOAD_AVERAGE": "12.5",
                "XCSTEWARD_MAX_LOAD_AVERAGE": "8.0",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ])
        )
        let store = try StateStore(environment: environment)

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 4), 1)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["configured_max_jobs"] as? Int, 4)
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 1)
        XCTAssertEqual(health["load_average"] as? Double, 12.5)
        XCTAssertEqual(health["max_load_average"] as? Double, 8.0)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("load_average=12.50/8.00") == true)
    }

    func testLoadAverageBelowThresholdDoesNotConstrainDispatch() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: [
                "XCSTEWARD_LOAD_AVERAGE": "2.5",
                "XCSTEWARD_MAX_LOAD_AVERAGE": "8.0",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ])
        )
        let store = try StateStore(environment: environment)

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 4), 4)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["load_average"] as? Double, 2.5)
        XCTAssertEqual(health["max_load_average"] as? Double, 8.0)
        XCTAssertFalse((health["reasons"] as? [String])?.contains("load_average=2.50/8.00") == true)
    }

    func testSampledMemoryPressureCanConstrainConcurrentDispatch() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .memoryPressureWarning,
            extraEnv: [
                "XCSTEWARD_SAMPLE_MEMORY_PRESSURE": "true",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ]
        )
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: fakeTools.env)
        )
        let store = try StateStore(environment: environment)

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3), 1)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 1)
        XCTAssertEqual(health["memory_pressure_sampling_enabled"] as? Bool, true)
        XCTAssertEqual(health["thermal_state_sampling_enabled"] as? Bool, false)
        XCTAssertEqual(health["memory_pressure"] as? String, "warning")
        XCTAssertEqual(health["memory_pressure_source"] as? String, "sampled")
        XCTAssertTrue((health["reasons"] as? [String])?.contains("memory_pressure=warning") == true)
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("memory_pressure"))
    }

    func testMemoryPressureEnvOverrideWinsOverSampling() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .memoryPressureWarning,
            extraEnv: [
                "XCSTEWARD_MEMORY_PRESSURE": "normal",
                "XCSTEWARD_SAMPLE_MEMORY_PRESSURE": "true",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ]
        )
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: fakeTools.env)
        )
        let store = try StateStore(environment: environment)

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3), 3)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["memory_pressure"] as? String, "normal")
        XCTAssertEqual(health["memory_pressure_sampling_enabled"] as? Bool, true)
        XCTAssertEqual(health["memory_pressure_source"] as? String, "env")
        XCTAssertFalse((health["reasons"] as? [String])?.contains("memory_pressure=warning") == true)
        if FileManager.default.fileExists(atPath: fakeTools.log.path) {
            let toolLog = try String(contentsOf: fakeTools.log)
            XCTAssertFalse(toolLog.contains("memory_pressure"))
        }
    }

    func testSampledThermalStateCanConstrainConcurrentDispatch() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .thermalStateSerious,
            extraEnv: [
                "XCSTEWARD_SAMPLE_THERMAL_STATE": "true",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ]
        )
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: fakeTools.env)
        )
        let store = try StateStore(environment: environment)

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3), 1)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 1)
        XCTAssertEqual(health["memory_pressure_sampling_enabled"] as? Bool, false)
        XCTAssertEqual(health["thermal_state_sampling_enabled"] as? Bool, true)
        XCTAssertEqual(health["thermal_state"] as? String, "serious")
        XCTAssertEqual(health["thermal_state_source"] as? String, "sampled")
        XCTAssertTrue((health["reasons"] as? [String])?.contains("thermal_state=serious") == true)
        let toolLog = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(toolLog.contains("pmset -g therm"))
    }

    func testThermalStateEnvOverrideWinsOverSampling() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .thermalStateSerious,
            extraEnv: [
                "XCSTEWARD_THERMAL_STATE": "nominal",
                "XCSTEWARD_SAMPLE_THERMAL_STATE": "true",
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore",
            ]
        )
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: fakeTools.env)
        )
        let store = try StateStore(environment: environment)

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3), 3)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["thermal_state"] as? String, "nominal")
        XCTAssertEqual(health["thermal_state_sampling_enabled"] as? Bool, true)
        XCTAssertEqual(health["thermal_state_source"] as? String, "env")
        XCTAssertFalse((health["reasons"] as? [String])?.contains("thermal_state=serious") == true)
        if FileManager.default.fileExists(atPath: fakeTools.log.path) {
            let toolLog = try String(contentsOf: fakeTools.log)
            XCTAssertFalse(toolLog.contains("pmset"))
        }
    }

    func testForeignRunnerActivityConstrainsConcurrentDispatchByDefault() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .concurrentRunnerContention)
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: fakeTools.env)
        )
        let store = try StateStore(environment: environment)

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3), 1)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["configured_max_jobs"] as? Int, 3)
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 1)
        XCTAssertEqual(health["foreign_activity_policy"] as? String, "capacity")
        XCTAssertEqual(health["foreign_runner_process_count"] as? Int, 1)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("foreign_runner_processes=1") == true)
    }

    func testForeignRunnerActivityCanBeIgnoredForCapacity() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .concurrentRunnerContention,
            extraEnv: ["XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "ignore"]
        )
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: fakeTools.env)
        )
        let store = try StateStore(environment: environment)

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3), 3)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["foreign_activity_policy"] as? String, "ignore")
        XCTAssertNil(health["foreign_runner_process_count"])
        XCTAssertFalse((health["reasons"] as? [String])?.contains("foreign_runner_processes=1") == true)
    }

    func testStrictForeignRunnerActivityStopsNewDispatch() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .concurrentRunnerContention,
            extraEnv: ["XCSTEWARD_FOREIGN_ACTIVITY_POLICY": "strict"]
        )
        let environment = AppEnvironment(
            paths: AppPaths(stateRoot: stateRoot),
            processInfo: StaticProcessInfo(environment: fakeTools.env)
        )
        let store = try StateStore(environment: environment)

        let capacity = HostCapacityController(environment: environment, store: store)
        XCTAssertEqual(try capacity.effectiveMaxConcurrentJobs(configuredMax: 3), 0)

        let health = try XCTUnwrap(
            parseJSON(String(contentsOf: stateRoot.appendingPathComponent("host-health.json"))) as? [String: Any]
        )
        XCTAssertEqual(health["foreign_activity_policy"] as? String, "strict")
        XCTAssertEqual(health["foreign_runner_process_count"] as? Int, 1)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("foreign_runner_processes=1") == true)
    }
}

private struct StaticProcessInfo: ProcessInfoProviding {
    var environment: [String: String]
    var arguments: [String] = []
}
