// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Darwin
import Foundation

struct HostCapacitySnapshot: Codable, Sendable {
    var configuredMaxJobs: Int
    var effectiveMaxJobs: Int
    var reasons: [String]
    var memoryPressureSamplingEnabled: Bool
    var memoryPressure: String?
    var memoryPressureSource: String?
    var thermalStateSamplingEnabled: Bool
    var thermalState: String?
    var thermalStateSource: String?
    var loadAverage: Double?
    var maxLoadAverage: Double?
    var bootedSimulatorCount: Int?
    var maxBootedSimulators: Int?
    var activeSimulatorLeaseCount: Int
    var maxActiveSimulatorLeases: Int?
    var recentInfrastructureFailures: Int
    var recentInfrastructureFailureLimit: Int
    var infrastructureFailureDrainLimit: Int
    var foreignActivityPolicy: String
    var foreignRunnerProcessCount: Int?
    var draining: Bool

    enum CodingKeys: String, CodingKey {
        case configuredMaxJobs = "configured_max_jobs"
        case effectiveMaxJobs = "effective_max_jobs"
        case reasons
        case memoryPressureSamplingEnabled = "memory_pressure_sampling_enabled"
        case memoryPressure = "memory_pressure"
        case memoryPressureSource = "memory_pressure_source"
        case thermalStateSamplingEnabled = "thermal_state_sampling_enabled"
        case thermalState = "thermal_state"
        case thermalStateSource = "thermal_state_source"
        case loadAverage = "load_average"
        case maxLoadAverage = "max_load_average"
        case bootedSimulatorCount = "booted_simulator_count"
        case maxBootedSimulators = "max_booted_simulators"
        case activeSimulatorLeaseCount = "active_simulator_lease_count"
        case maxActiveSimulatorLeases = "max_active_simulator_leases"
        case recentInfrastructureFailures = "recent_infrastructure_failures"
        case recentInfrastructureFailureLimit = "recent_infrastructure_failure_limit"
        case infrastructureFailureDrainLimit = "infrastructure_failure_drain_limit"
        case foreignActivityPolicy = "foreign_activity_policy"
        case foreignRunnerProcessCount = "foreign_runner_process_count"
        case draining
    }
}

final class HostCapacityController {
    private let environment: AppEnvironment
    private let store: StateStore
    private let parser = HostCapacityParser()

    init(environment: AppEnvironment, store: StateStore) {
        self.environment = environment
        self.store = store
    }

    func effectiveMaxConcurrentJobs(configuredMax: Int, activeJobCount: Int = 0) throws -> Int {
        let snapshot = try makeSnapshot(configuredMax: configuredMax, activeJobCount: activeJobCount)
        try? writeSnapshot(snapshot)
        return snapshot.effectiveMaxJobs
    }

    private func makeSnapshot(configuredMax: Int, activeJobCount: Int) throws -> HostCapacitySnapshot {
        let configuredMax = max(1, configuredMax)
        let activeJobCount = max(0, activeJobCount)
        let env = environment.processInfo.environment
        var effectiveMax = configuredMax
        var reasons: [String] = []
        let memoryPressureSamplingEnabled = parser.bool(env["XCSTEWARD_SAMPLE_MEMORY_PRESSURE"])
        let thermalStateSamplingEnabled = parser.bool(env["XCSTEWARD_SAMPLE_THERMAL_STATE"])

        let memoryPressureSample = memoryPressure()
        let memoryPressure = memoryPressureSample.value
        if parser.isConstrainedMemoryPressure(memoryPressure) {
            effectiveMax = min(effectiveMax, 1)
            reasons.append("memory_pressure=\(memoryPressure ?? "unknown")")
        }

        let thermalStateSample = thermalState()
        let thermalState = thermalStateSample.value
        if parser.isConstrainedThermalState(thermalState) {
            effectiveMax = min(effectiveMax, 1)
            reasons.append("thermal_state=\(thermalState ?? "unknown")")
        }

        let maxLoadAverage = parser.double(env["XCSTEWARD_MAX_LOAD_AVERAGE"])
        let loadAverage = loadAverage(limitConfigured: maxLoadAverage != nil)
        if let maxLoadAverage, maxLoadAverage > 0,
           let loadAverage,
           loadAverage >= maxLoadAverage {
            effectiveMax = min(effectiveMax, 1)
            reasons.append("load_average=\(parser.formatLoadAverage(loadAverage))/\(parser.formatLoadAverage(maxLoadAverage))")
        }

        let failureLimit = parser.integer(env["XCSTEWARD_RECENT_INFRA_FAILURE_LIMIT"]) ?? 3
        let failureWindow = Double(parser.integer(env["XCSTEWARD_RECENT_INFRA_FAILURE_WINDOW_SECONDS"]) ?? 600)
        let since = environment.clock.now().timeIntervalSince1970 - failureWindow
        let recentFailures = failureLimit > 0
            ? try store.countRecentInfrastructureFailures(since: since)
            : 0
        if failureLimit > 0, recentFailures >= failureLimit {
            effectiveMax = min(effectiveMax, 1)
            reasons.append("recent_infrastructure_failures=\(recentFailures)")
        }
        let drainLimit = parser.integer(env["XCSTEWARD_INFRA_FAILURE_DRAIN_LIMIT"]) ?? 0
        let draining = drainLimit > 0 && recentFailures >= drainLimit
        if draining {
            effectiveMax = 0
            reasons.append("drain_recent_infrastructure_failures=\(recentFailures)")
        }

        let foreignActivityPolicy = parser.normalizedForeignActivityPolicy(env["XCSTEWARD_FOREIGN_ACTIVITY_POLICY"])
        let foreignRunnerProcessCount = foreignActivityPolicy == "ignore"
            ? nil
            : competingRunnerProcessCount()
        if let foreignRunnerProcessCount, foreignRunnerProcessCount > 0 {
            switch foreignActivityPolicy {
            case "strict":
                effectiveMax = 0
                reasons.append("foreign_runner_processes=\(foreignRunnerProcessCount)")
            case "capacity":
                effectiveMax = min(effectiveMax, 1)
                reasons.append("foreign_runner_processes=\(foreignRunnerProcessCount)")
            default:
                effectiveMax = min(effectiveMax, 1)
                reasons.append("foreign_runner_processes=\(foreignRunnerProcessCount)")
            }
        }

        let activeSimulatorLeaseCount = try activeSimulatorLeaseCount()
        let maxActiveSimulatorLeases = parser.integer(env["XCSTEWARD_MAX_ACTIVE_SIMULATOR_LEASES"])
        if let maxActiveSimulatorLeases, maxActiveSimulatorLeases > 0 {
            let consumedSlots = max(activeSimulatorLeaseCount, activeJobCount)
            let availableSlots = max(0, maxActiveSimulatorLeases - consumedSlots)
            let leaseLimitedMax = activeJobCount + availableSlots
            if leaseLimitedMax < effectiveMax {
                effectiveMax = leaseLimitedMax
                reasons.append("active_simulator_leases=\(activeSimulatorLeaseCount)/\(maxActiveSimulatorLeases)")
            }
        }

        let maxBootedSimulators = parser.integer(env["XCSTEWARD_MAX_BOOTED_SIMULATORS"])
        let bootedSimulatorCount = try bootedSimulatorCount(limitConfigured: maxBootedSimulators != nil)
        if let maxBootedSimulators, maxBootedSimulators > 0,
           let bootedSimulatorCount,
           bootedSimulatorCount >= maxBootedSimulators {
            effectiveMax = min(effectiveMax, 1)
            reasons.append("booted_simulators=\(bootedSimulatorCount)")
        }

        return HostCapacitySnapshot(
            configuredMaxJobs: configuredMax,
            effectiveMaxJobs: max(0, effectiveMax),
            reasons: reasons,
            memoryPressureSamplingEnabled: memoryPressureSamplingEnabled,
            memoryPressure: memoryPressure,
            memoryPressureSource: memoryPressureSample.source,
            thermalStateSamplingEnabled: thermalStateSamplingEnabled,
            thermalState: thermalState,
            thermalStateSource: thermalStateSample.source,
            loadAverage: loadAverage,
            maxLoadAverage: maxLoadAverage,
            bootedSimulatorCount: bootedSimulatorCount,
            maxBootedSimulators: maxBootedSimulators,
            activeSimulatorLeaseCount: activeSimulatorLeaseCount,
            maxActiveSimulatorLeases: maxActiveSimulatorLeases,
            recentInfrastructureFailures: recentFailures,
            recentInfrastructureFailureLimit: failureLimit,
            infrastructureFailureDrainLimit: drainLimit,
            foreignActivityPolicy: foreignActivityPolicy,
            foreignRunnerProcessCount: foreignRunnerProcessCount,
            draining: draining
        )
    }

    private func writeSnapshot(_ snapshot: HostCapacitySnapshot) throws {
        let url = environment.paths.stateRoot.appendingPathComponent("host-health.json")
        try environment.fileSystem.writeData(try jsonData(snapshot), to: url)
    }

    private func memoryPressure() -> (value: String?, source: String?) {
        let env = environment.processInfo.environment
        if let override = parser.normalized(env["XCSTEWARD_MEMORY_PRESSURE"]) {
            return (override, "env")
        }
        guard parser.bool(env["XCSTEWARD_SAMPLE_MEMORY_PRESSURE"]) else {
            return (nil, nil)
        }
        let result: ToolResult
        do {
            result = try environment.toolRunner.run(
                tool: "memory_pressure",
                arguments: [],
                environment: env,
                workingDirectory: nil,
                timeout: 2
            )
        } catch {
            return (nil, nil)
        }
        guard result.exitCode == 0, !result.timedOut else {
            return (nil, nil)
        }
        guard let parsed = parser.parseMemoryPressure(result.output) else {
            return (nil, nil)
        }
        return (parsed, "sampled")
    }

    private func thermalState() -> (value: String?, source: String?) {
        let env = environment.processInfo.environment
        if let override = parser.normalized(env["XCSTEWARD_THERMAL_STATE"]) {
            return (override, "env")
        }
        guard parser.bool(env["XCSTEWARD_SAMPLE_THERMAL_STATE"]) else {
            return (nil, nil)
        }
        let result: ToolResult
        do {
            result = try environment.toolRunner.run(
                tool: "pmset",
                arguments: ["-g", "therm"],
                environment: env,
                workingDirectory: nil,
                timeout: 2
            )
        } catch {
            return (nil, nil)
        }
        guard result.exitCode == 0, !result.timedOut else {
            return (nil, nil)
        }
        guard let parsed = parser.parseThermalState(result.output) else {
            return (nil, nil)
        }
        return (parsed, "sampled")
    }

    private func loadAverage(limitConfigured: Bool) -> Double? {
        let env = environment.processInfo.environment
        if let override = parser.double(env["XCSTEWARD_LOAD_AVERAGE"]) {
            return override
        }
        guard limitConfigured else {
            return nil
        }
        var samples = [Double](repeating: 0, count: 3)
        guard getloadavg(&samples, Int32(samples.count)) > 0 else {
            return nil
        }
        return samples[0]
    }

    private func bootedSimulatorCount(limitConfigured: Bool) throws -> Int? {
        let env = environment.processInfo.environment
        if let override = parser.integer(env["XCSTEWARD_BOOTED_SIMULATOR_COUNT"]) {
            return override
        }
        guard limitConfigured else {
            return nil
        }
        let result: ToolResult
        do {
            result = try environment.toolRunner.run(
                tool: "xcrun",
                arguments: ["simctl", "list", "devices", "booted", "--json"],
                environment: [:],
                workingDirectory: nil,
                timeout: 2
            )
        } catch {
            return nil
        }
        guard result.exitCode == 0, !result.timedOut, let data = result.output.data(using: .utf8) else {
            return nil
        }
        return parser.countBootedSimulators(in: data)
    }

    private func activeSimulatorLeaseCount() throws -> Int {
        try store.listSimulatorLeases().filter { isPIDAlive($0.pid) }.count
    }

    private func competingRunnerProcessCount() -> Int? {
        let result: ToolResult
        do {
            result = try environment.toolRunner.run(
                tool: "ps",
                arguments: ["-Ao", "pid,command"],
                environment: environment.processInfo.environment,
                workingDirectory: nil,
                timeout: 2
            )
        } catch {
            return nil
        }
        guard result.exitCode == 0, !result.timedOut else {
            return nil
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return RunnerProcessDetector.records(from: result.output)
            .filter { process in
                process.pid != currentPID &&
                    RunnerProcessDetector.isCompeting(command: process.command, policy: .executor)
            }
            .count
    }

}
