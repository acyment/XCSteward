// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct DoctorStateHealth {
    let environment: AppEnvironment
    let store: StateStore

    func stateRootHealthCheck() throws -> DoctorCheck {
        do {
            try environment.fileSystem.createDirectory(environment.paths.stateRoot)
            return DoctorCheck(id: "global.state_root", status: .pass, message: "State root is available", autoFixable: false, fixed: false, manualAction: nil)
        } catch {
            return DoctorCheck(id: "global.state_root", status: .fail, message: "State root is unavailable", autoFixable: true, fixed: false, manualAction: "Create a writable state root")
        }
    }

    func workerLeaseHealthCheck(fix: Bool) throws -> DoctorCheck {
        var staleLeaseFixed = false
        if try store.recoverStaleLeaseIfNeeded() {
            staleLeaseFixed = true
        } else if fix {
            let legacy = environment.paths.stateRoot.appendingPathComponent("stale-lease.json")
            if environment.fileSystem.fileExists(legacy) {
                try environment.fileSystem.removeItem(legacy)
                staleLeaseFixed = true
            }
        }
        if staleLeaseFixed {
            return DoctorCheck(id: "global.worker_lease", status: .pass, message: "Recovered stale worker lease", autoFixable: true, fixed: true, manualAction: nil)
        }
        if let lease = try store.currentLease(), !isPIDAlive(lease.pid) {
            return DoctorCheck(id: "global.worker_lease", status: .fail, message: "Stale worker lease detected", autoFixable: true, fixed: false, manualAction: "Run doctor --fix")
        }
        if environment.fileSystem.fileExists(environment.paths.stateRoot.appendingPathComponent("stale-lease.json")) {
            return DoctorCheck(id: "global.worker_lease", status: .fail, message: "Legacy stale lease marker detected", autoFixable: true, fixed: false, manualAction: "Run doctor --fix")
        }
        return DoctorCheck(id: "global.worker_lease", status: .pass, message: "No stale worker lease detected", autoFixable: false, fixed: false, manualAction: nil)
    }

    func simulatorLeaseHealthCheck(fix: Bool) throws -> DoctorCheck {
        let staleLeases = try store.listSimulatorLeases().filter { !isPIDAlive($0.pid) }
        guard !staleLeases.isEmpty else {
            let activeCount = try store.listSimulatorLeases().count
            return DoctorCheck(
                id: "global.simulator_leases",
                status: .pass,
                message: activeCount == 0
                    ? "No simulator leases are recorded"
                    : "\(activeCount) active simulator lease\(activeCount == 1 ? "" : "s") recorded",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }
        if fix {
            let recovered = try store.recoverStaleSimulatorLeases()
            return DoctorCheck(
                id: "global.simulator_leases",
                status: .pass,
                message: "Recovered \(recovered) stale simulator lease\(recovered == 1 ? "" : "s")",
                autoFixable: true,
                fixed: true,
                manualAction: nil
            )
        }
        let simulatorIDs = staleLeases.map(\.simulatorID).joined(separator: ", ")
        return DoctorCheck(
            id: "global.simulator_leases",
            status: .fail,
            message: "Stale simulator lease\(staleLeases.count == 1 ? "" : "s") detected: \(simulatorIDs)",
            autoFixable: true,
            fixed: false,
            manualAction: "Run doctor --fix to remove simulator leases owned by dead XCSteward processes"
        )
    }

    func concurrentRunnerContentionCheck() throws -> DoctorCheck {
        let processes: ToolResult
        do {
            processes = try environment.toolRunner.run(
                tool: "ps",
                arguments: ["-Ao", "pid,command"],
                environment: [:],
                workingDirectory: nil,
                timeout: 5
            )
        } catch {
            return processListingUnavailableCheck()
        }
        guard processes.exitCode == 0 else {
            return processListingUnavailableCheck()
        }

        let competingProcesses = RunnerProcessDetector.records(from: processes.output)
            .map(\.command)
            .filter { RunnerProcessDetector.isCompeting(command: $0, policy: .doctor) }

        if competingProcesses.isEmpty {
            return DoctorCheck(
                id: "global.concurrent_runner_contention",
                status: .pass,
                message: "No competing local runner processes were detected",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }
        return DoctorCheck(
            id: "global.concurrent_runner_contention",
            status: .warn,
            message: "Competing local runner processes are active: \(competingProcesses[0])",
            autoFixable: false,
            fixed: false,
            manualAction: "Wait for the competing simulator activity to finish or route it through XCSteward"
        )
    }

    private func processListingUnavailableCheck() -> DoctorCheck {
        DoctorCheck(
            id: "global.concurrent_runner_contention",
            status: .warn,
            message: "Unable to determine whether competing local runner processes are active",
            autoFixable: false,
            fixed: false,
            manualAction: "Inspect active xcodebuild, xctest, or simctl processes manually"
        )
    }
}
