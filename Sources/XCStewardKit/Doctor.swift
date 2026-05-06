import Foundation

private enum DoctorProbeFailure: Error {
    case timedOut
    case nonZeroExit
    case invalidJSON
}

private struct ProtectedProfilePath {
    var label: String
    var url: URL
}

struct DoctorProjectCheckContext {
    let profile: ProjectProfile
    let fixOptions: DoctorFixOptions
    let schemeAvailable: Bool
}

struct DoctorFixOptions {
    let applySafeFixes: Bool
    let applyGlobalFixes: Bool
}

struct DoctorGlobalCheckDescriptor: @unchecked Sendable {
    let id: String
    let run: (DoctorEngine, DoctorFixOptions) throws -> [DoctorCheck]
}

struct DoctorProjectCheckDescriptor: @unchecked Sendable {
    let id: String
    let run: (DoctorEngine, DoctorProjectCheckContext) throws -> [DoctorCheck]
}

final class DoctorEngine {
    private let environment: AppEnvironment
    private let store: StateStore
    private let profileLoader: ProfileLoader

    static let globalCheckRegistry: [DoctorGlobalCheckDescriptor] = [
        DoctorGlobalCheckDescriptor(id: "global.state_root") { engine, _ in
            [try engine.stateRootHealthCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.free_disk_space") { engine, _ in
            [engine.freeDiskSpaceCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.developer_dir_env_override") { engine, _ in
            [try engine.developerDirEnvironmentOverrideCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.clt_vs_xcode_selection") { engine, _ in
            [try engine.commandLineToolsSelectionCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.first_launch_components") { engine, _ in
            [try engine.firstLaunchComponentsCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.iphonesimulator_sdk_present") { engine, _ in
            [try engine.iPhoneSimulatorSDKPresenceCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.simulator_runtime_installed") { engine, _ in
            [try engine.simulatorRuntimeInstalledCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.simulator_runtime_unavailable") { engine, _ in
            [try engine.simulatorRuntimeUnavailableCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.runtime_dyld_cache_state") { engine, _ in
            [try engine.runtimeDyldCacheStateCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.unavailable_devices_cleanup") { engine, fixOptions in
            [try engine.unavailableDevicesCleanupCheck(fixOptions: fixOptions)]
        },
        DoctorGlobalCheckDescriptor(id: "global.coresim_list_json_health") { engine, _ in
            [try engine.coreSimulatorListJSONHealthCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.concurrent_runner_contention") { engine, _ in
            [try engine.concurrentRunnerContentionCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.disk_pressure_warning") { engine, _ in
            [engine.diskPressureWarningCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.protected_path_warning") { engine, _ in
            [engine.protectedPathWarningCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.xcode_cli_alignment") { engine, _ in
            [try engine.xcodeCLIAlignmentCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.worker_lease") { engine, fixOptions in
            [try engine.workerLeaseHealthCheck(fix: fixOptions.applySafeFixes)]
        },
        DoctorGlobalCheckDescriptor(id: "global.simulator_leases") { engine, fixOptions in
            [try engine.simulatorLeaseHealthCheck(fix: fixOptions.applySafeFixes)]
        },
    ]

    static let projectCheckRegistry: [DoctorProjectCheckDescriptor] = [
        DoctorProjectCheckDescriptor(id: "project.repo_root") { engine, context in
            [engine.repoRootCheck(profile: context.profile)]
        },
        DoctorProjectCheckDescriptor(id: "project.project_path") { engine, context in
            engine.projectPathCheck(profile: context.profile)
        },
        DoctorProjectCheckDescriptor(id: "project.scheme") { engine, context in
            [engine.schemeCheck(profile: context.profile, schemeAvailable: context.schemeAvailable)]
        },
        DoctorProjectCheckDescriptor(id: "project.showdestinations_runnable") { engine, context in
            [try engine.showDestinationsRunnableCheck(profile: context.profile, schemeAvailable: context.schemeAvailable)]
        },
        DoctorProjectCheckDescriptor(id: "project.testplan_exists") { engine, context in
            [try engine.configuredTestPlanCheck(profile: context.profile, schemeAvailable: context.schemeAvailable)]
        },
        DoctorProjectCheckDescriptor(id: "project.derived_data_isolation") { engine, context in
            [engine.derivedDataIsolationCheck(profile: context.profile)]
        },
        DoctorProjectCheckDescriptor(id: "project.protected_path_warning") { engine, context in
            [engine.projectProtectedPathWarningCheck(profile: context.profile)]
        },
        DoctorProjectCheckDescriptor(id: "project.xcode_managed_parallel_workers") { engine, context in
            [engine.parallelCloneRiskCheck(profile: context.profile)]
        },
        DoctorProjectCheckDescriptor(id: "project.package_resolution_preflight") { engine, context in
            [try engine.packageResolutionPreflightCheck(profile: context.profile, schemeAvailable: context.schemeAvailable)]
        },
        DoctorProjectCheckDescriptor(id: "project.xctestrun_integrity") { engine, context in
            [try engine.xctestrunIntegrityCheck(profile: context.profile, schemeAvailable: context.schemeAvailable)]
        },
        DoctorProjectCheckDescriptor(id: "project.xcresulttool_compat") { engine, _ in
            [try engine.xcresulttoolCompatibilityCheck()]
        },
        DoctorProjectCheckDescriptor(id: "project.default_simulator_bootstatus") { engine, context in
            guard let simulatorID = context.profile.defaultSimulatorID else {
                return []
            }
            return [try engine.configuredSimulatorBootstatusCheck(profile: context.profile, simulatorID: simulatorID)]
        },
        DoctorProjectCheckDescriptor(id: "project.managed_simulator") { engine, context in
            try engine.managedSimulatorCheck(profile: context.profile, fix: context.fixOptions.applySafeFixes)
        },
    ]

    static var globalCheckIDs: [String] {
        globalCheckRegistry.map(\.id)
    }

    static var projectCheckIDs: [String] {
        projectCheckRegistry.map(\.id)
    }

    init(environment: AppEnvironment, store: StateStore) {
        self.environment = environment
        self.store = store
        self.profileLoader = ProfileLoader(environment: environment)
    }

    private func makeCheck(
        id: String,
        status: DoctorStatus,
        message: String,
        autoFixable: Bool = false,
        fixed: Bool = false,
        manualAction: String? = nil
    ) -> DoctorCheck {
        DoctorCheck(
            id: id,
            status: status,
            message: message,
            autoFixable: autoFixable,
            fixed: fixed,
            manualAction: manualAction
        )
    }

    func run(project: String?, fixOptions: DoctorFixOptions) throws -> DoctorReport {
        var checks = try runGlobalChecks(fixOptions: fixOptions)

        if let project {
            let profile = try profileLoader.loadProfile(named: project)
            checks.append(contentsOf: try projectChecks(profile: profile, fixOptions: fixOptions))
        }

        let overallStatus: DoctorStatus
        if checks.contains(where: { $0.status == .fail }) {
            overallStatus = .fail
        } else if checks.contains(where: { $0.status == .warn }) {
            overallStatus = .warn
        } else {
            overallStatus = .pass
        }
        let report = DoctorReport(overallStatus: overallStatus, checks: checks, profilesChecked: project.map { [$0] } ?? [])
        try environment.fileSystem.writeData(try jsonData(report), to: environment.paths.doctorRoot.appendingPathComponent("last-report.json"))
        return report
    }

    private func runGlobalChecks(fixOptions: DoctorFixOptions) throws -> [DoctorCheck] {
        try Self.globalCheckRegistry.flatMap { descriptor in
            try descriptor.run(self, fixOptions)
        }
    }

    private func stateRootHealthCheck() throws -> DoctorCheck {
        do {
            try environment.fileSystem.createDirectory(environment.paths.stateRoot)
            return DoctorCheck(id: "global.state_root", status: .pass, message: "State root is available", autoFixable: false, fixed: false, manualAction: nil)
        } catch {
            return DoctorCheck(id: "global.state_root", status: .fail, message: "State root is unavailable", autoFixable: true, fixed: false, manualAction: "Create a writable state root")
        }
    }

    private func workerLeaseHealthCheck(fix: Bool) throws -> DoctorCheck {
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

    private func freeDiskSpaceCheck() -> DoctorCheck {
        let path = environment.paths.stateRoot.path
        let failThreshold = diskThresholdBytes(
            environmentKey: "XCSTEWARD_DOCTOR_MIN_FREE_BYTES",
            defaultBytes: 2 * 1024 * 1024 * 1024
        )
        let warnThreshold = diskThresholdBytes(
            environmentKey: "XCSTEWARD_DOCTOR_WARN_FREE_BYTES",
            defaultBytes: 10 * 1024 * 1024 * 1024
        )

        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            guard let freeBytes = attributes[.systemFreeSize] as? NSNumber else {
                return DoctorCheck(
                    id: "global.free_disk_space",
                    status: .warn,
                    message: "Unable to read available disk space for \(path)",
                    autoFixable: false,
                    fixed: false,
                    manualAction: "Check free disk space manually before running simulator tests"
                )
            }

            let available = freeBytes.int64Value
            if available < failThreshold {
                return DoctorCheck(
                    id: "global.free_disk_space",
                    status: .fail,
                    message: "Only \(formatBytes(available)) free on the XCSteward state volume",
                    autoFixable: false,
                    fixed: false,
                    manualAction: "Free at least \(formatBytes(failThreshold)) before running SwiftPM or simulator jobs"
                )
            }
            if available < warnThreshold {
                return DoctorCheck(
                    id: "global.free_disk_space",
                    status: .warn,
                    message: "Only \(formatBytes(available)) free on the XCSteward state volume",
                    autoFixable: false,
                    fixed: false,
                    manualAction: "Free disk space before long simulator runs to avoid xcodebuild or SwiftPM I/O failures"
                )
            }

            return DoctorCheck(
                id: "global.free_disk_space",
                status: .pass,
                message: "\(formatBytes(available)) free on the XCSteward state volume",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        } catch {
            return DoctorCheck(
                id: "global.free_disk_space",
                status: .warn,
                message: "Unable to inspect disk space for \(path)",
                autoFixable: false,
                fixed: false,
                manualAction: "Check free disk space manually before running simulator tests"
            )
        }
    }

    private func simulatorLeaseHealthCheck(fix: Bool) throws -> DoctorCheck {
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

    private func projectChecks(profile: ProjectProfile, fixOptions: DoctorFixOptions) throws -> [DoctorCheck] {
        let schemeAvailable = try isSchemeAvailable(profile: profile)
        let context = DoctorProjectCheckContext(profile: profile, fixOptions: fixOptions, schemeAvailable: schemeAvailable)
        return try Self.projectCheckRegistry.flatMap { descriptor in
            try descriptor.run(self, context)
        }
    }

    private func repoRootCheck(profile: ProjectProfile) -> DoctorCheck {
        if environment.fileSystem.fileExists(URL(fileURLWithPath: profile.repoRoot)) {
            return DoctorCheck(id: "project.repo_root", status: .pass, message: "Repo root exists", autoFixable: false, fixed: false, manualAction: nil)
        }
        return DoctorCheck(id: "project.repo_root", status: .fail, message: "Repo root is missing", autoFixable: false, fixed: false, manualAction: "Restore the repository at \(profile.repoRoot)")
    }

    private func projectPathCheck(profile: ProjectProfile) -> [DoctorCheck] {
        let repoURL = URL(fileURLWithPath: profile.repoRoot)
        if let projectPath = profile.projectPath, environment.fileSystem.fileExists(repoURL.appendingPathComponent(projectPath)) {
            return [DoctorCheck(id: "project.project_path", status: .pass, message: "Project path exists", autoFixable: false, fixed: false, manualAction: nil)]
        }
        return []
    }

    private func isSchemeAvailable(profile: ProjectProfile) throws -> Bool {
        let schemes = try environment.toolRunner.run(
            tool: "xcodebuild",
            arguments: xcodebuildProjectArguments(for: profile, includeScheme: false) + ["-list", "-json"],
            environment: profile.env,
            workingDirectory: profile.workingDirectory,
            timeout: profile.timeouts.build
        )
        return schemes.exitCode == 0 &&
            availableSchemes(from: schemes.output).contains(profile.scheme)
    }

    private func schemeCheck(profile: ProjectProfile, schemeAvailable: Bool) -> DoctorCheck {
        if schemeAvailable {
            return DoctorCheck(id: "project.scheme", status: .pass, message: "Scheme is available", autoFixable: false, fixed: false, manualAction: nil)
        }
        return DoctorCheck(id: "project.scheme", status: .fail, message: "Scheme is missing", autoFixable: false, fixed: false, manualAction: "Regenerate or share the expected scheme")
    }

    private func managedSimulatorCheck(profile: ProjectProfile, fix: Bool) throws -> [DoctorCheck] {
        guard let managed = profile.managedSimulator else {
            return []
        }
        let context = ToolExecutionContext(profile: profile, jobID: "doctor", store: store)
        let lifecycle = SimulatorLifecycle(environment: environment, tooling: self)
        if try lifecycle.existingManagedSimulatorID(managed, context: context) != nil {
            return [DoctorCheck(id: "project.managed_simulator", status: .pass, message: "Managed simulator exists", autoFixable: true, fixed: false, manualAction: nil)]
        }
        if fix {
            do {
                _ = try lifecycle.createManagedSimulator(managed, context: context)
                return [DoctorCheck(id: "project.managed_simulator", status: .pass, message: "Managed simulator created", autoFixable: true, fixed: true, manualAction: nil)]
            } catch {
                return [DoctorCheck(id: "project.managed_simulator", status: .fail, message: "Unable to create managed simulator", autoFixable: true, fixed: false, manualAction: "Create the simulator manually")]
            }
        }
        return [DoctorCheck(id: "project.managed_simulator", status: .fail, message: "Managed simulator is missing", autoFixable: true, fixed: false, manualAction: "Run doctor --fix")]
    }

    private func parallelCloneRiskCheck(profile: ProjectProfile) -> DoctorCheck {
        switch profile.parallel.mode {
        case .serial, .manualShards:
            return DoctorCheck(
                id: "project.xcode_managed_parallel_workers",
                status: .pass,
                message: "Parallel configuration avoids Xcode-managed clone simulators",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        case .xcodeManaged, .hybrid:
            guard profile.parallel.maxWorkers > 1 else {
                return DoctorCheck(
                    id: "project.xcode_managed_parallel_workers",
                    status: .pass,
                    message: "Xcode-managed parallelism is limited to one worker",
                    autoFixable: false,
                    fixed: false,
                    manualAction: nil
                )
            }
            return DoctorCheck(
                id: "project.xcode_managed_parallel_workers",
                status: .warn,
                message: "Xcode-managed parallelism may create clone simulators that doctor cannot fully preflight",
                autoFixable: false,
                fixed: false,
                manualAction: "Use [parallel] max_workers = 1 or mode = \"serial\" for deterministic local simulator runs; opt into higher worker counts only after a live smoke job proves clone launch stability"
            )
        }
    }

    private func configuredSimulatorBootstatusCheck(profile: ProjectProfile, simulatorID: String) throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "project.default_simulator_bootstatus",
            summary: "Configured simulator bootstatus"
        ) {
            return skipped
        }

        let devices = try environment.toolRunner.run(
            tool: "xcrun",
            arguments: ["simctl", "list", "devices"],
            environment: profile.env,
            workingDirectory: profile.workingDirectory,
            timeout: min(profile.timeouts.boot, 10)
        )
        if devices.timedOut {
            return DoctorCheck(
                id: "project.default_simulator_bootstatus",
                status: .fail,
                message: "Configured simulator state inspection timed out",
                autoFixable: false,
                fixed: false,
                manualAction: "Inspect CoreSimulator health manually and rerun doctor once simctl list devices returns promptly"
            )
        }
        guard devices.exitCode == 0 else {
            return DoctorCheck(
                id: "project.default_simulator_bootstatus",
                status: .fail,
                message: "Unable to inspect the configured simulator state",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcrun simctl list devices manually and inspect CoreSimulator errors"
            )
        }
        guard let line = simulatorLine(from: devices.output, simulatorID: simulatorID) else {
            return DoctorCheck(
                id: "project.default_simulator_bootstatus",
                status: .fail,
                message: "Configured simulator \(simulatorID) is missing from simctl list devices",
                autoFixable: false,
                fixed: false,
                manualAction: "Recreate or update the configured simulator before rerunning doctor"
            )
        }
        guard line.contains("(Booted)") else {
            return DoctorCheck(
                id: "project.default_simulator_bootstatus",
                status: .pass,
                message: "Configured simulator is not currently booted; live bootstatus probe skipped",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let bootStatus = try environment.toolRunner.run(
            tool: "xcrun",
            arguments: ["simctl", "bootstatus", simulatorID, "-b"],
            environment: profile.env,
            workingDirectory: profile.workingDirectory,
            timeout: min(profile.timeouts.boot, 10)
        )
        guard bootStatus.exitCode == 0, !bootStatus.timedOut else {
            let detail = bootStatus.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            return DoctorCheck(
                id: "project.default_simulator_bootstatus",
                status: .fail,
                message: "Configured booted simulator did not respond cleanly to bootstatus\(suffix)",
                autoFixable: false,
                fixed: false,
                manualAction: "Shutdown or erase the dedicated simulator, then rerun doctor"
            )
        }

        return DoctorCheck(
            id: "project.default_simulator_bootstatus",
            status: .pass,
            message: "Configured booted simulator responds to bootstatus",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func simulatorLine(from output: String, simulatorID: String) -> String? {
        output
            .split(separator: "\n")
            .map(String.init)
            .first { $0.contains("(\(simulatorID))") }
    }

    private func showDestinationsRunnableCheck(profile: ProjectProfile, schemeAvailable: Bool) throws -> DoctorCheck {
        guard schemeAvailable else {
            return DoctorCheck(
                id: "project.showdestinations_runnable",
                status: .pass,
                message: "Destination check skipped because the configured scheme is unavailable",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let result = try environment.toolRunner.run(
            tool: "xcodebuild",
            arguments: xcodebuildProjectArguments(for: profile, includeScheme: true) + ["-showdestinations"],
            environment: profile.env,
            workingDirectory: profile.workingDirectory,
            timeout: profile.timeouts.build
        )
        guard result.exitCode == 0 else {
            return DoctorCheck(
                id: "project.showdestinations_runnable",
                status: .fail,
                message: "Unable to inspect runnable destinations for the configured scheme",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcodebuild -showdestinations for the configured project and scheme"
            )
        }
        guard DoctorOutputParsers.showDestinationsOutputExposesIOSSimulator(result.output) else {
            return DoctorCheck(
                id: "project.showdestinations_runnable",
                status: .fail,
                message: "The configured scheme does not expose a runnable iOS Simulator destination",
                autoFixable: false,
                fixed: false,
                manualAction: "Adjust the scheme or destination settings until an iOS Simulator destination is runnable"
            )
        }

        return DoctorCheck(
            id: "project.showdestinations_runnable",
            status: .pass,
            message: "The configured scheme exposes a runnable iOS Simulator destination",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func configuredTestPlanCheck(profile: ProjectProfile, schemeAvailable: Bool) throws -> DoctorCheck {
        guard let testPlan = profile.defaultTestPlan, !testPlan.isEmpty else {
            return DoctorCheck(
                id: "project.testplan_exists",
                status: .pass,
                message: "No explicit test plan is configured in the profile",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }
        guard schemeAvailable else {
            return DoctorCheck(
                id: "project.testplan_exists",
                status: .pass,
                message: "Test plan check skipped because the configured scheme is unavailable",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let result = try environment.toolRunner.run(
            tool: "xcodebuild",
            arguments: xcodebuildProjectArguments(for: profile, includeScheme: true) + ["-showTestPlans"],
            environment: profile.env,
            workingDirectory: profile.workingDirectory,
            timeout: profile.timeouts.build
        )
        guard result.exitCode == 0 else {
            return DoctorCheck(
                id: "project.testplan_exists",
                status: .fail,
                message: "Unable to inspect configured test plans for the scheme",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcodebuild -showTestPlans for the configured project and scheme"
            )
        }
        guard result.output
            .split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .contains(testPlan) else {
            return DoctorCheck(
                id: "project.testplan_exists",
                status: .fail,
                message: "Configured test plan '\(testPlan)' is not available for the scheme",
                autoFixable: false,
                fixed: false,
                manualAction: "Update the profile to use an available test plan or restore '\(testPlan)' to the scheme"
            )
        }

        return DoctorCheck(
            id: "project.testplan_exists",
            status: .pass,
            message: "Configured test plan '\(testPlan)' is available",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func derivedDataIsolationCheck(profile: ProjectProfile) -> DoctorCheck {
        let repoURL = URL(fileURLWithPath: profile.repoRoot).standardizedFileURL
        let configuredPath = profile.env["DERIVED_DATA_PATH"] ?? profile.env["SYMROOT"] ?? profile.env["OBJROOT"]

        guard let configuredPath, !configuredPath.isEmpty else {
            return DoctorCheck(
                id: "project.derived_data_isolation",
                status: .pass,
                message: "XCSteward will isolate DerivedData per job by default",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let resolved = URL(fileURLWithPath: configuredPath).standardizedFileURL
        if resolved.path.hasPrefix(repoURL.path) {
            return DoctorCheck(
                id: "project.derived_data_isolation",
                status: .warn,
                message: "DerivedData is configured inside the repository, which weakens per-job isolation",
                autoFixable: false,
                fixed: false,
                manualAction: "Remove the explicit DerivedData override or move it outside the repository"
            )
        }
        if !resolved.path.hasPrefix(environment.paths.stateRoot.path) {
            return DoctorCheck(
                id: "project.derived_data_isolation",
                status: .warn,
                message: "DerivedData is configured outside XCSteward job state and may be shared across runs",
                autoFixable: false,
                fixed: false,
                manualAction: "Prefer XCSteward-managed per-job DerivedData paths instead of a shared override"
            )
        }

        return DoctorCheck(
            id: "project.derived_data_isolation",
            status: .pass,
            message: "DerivedData is configured under XCSteward-managed state",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func projectProtectedPathWarningCheck(profile: ProjectProfile) -> DoctorCheck {
        let matches = protectedProfilePaths(profile: profile).compactMap { entry -> String? in
            let normalized = normalizePath(entry.url.path)
            guard let matched = protectedPathPrefix(for: normalized) else {
                return nil
            }
            return "\(entry.label): \(normalized) under \(matched)"
        }
        guard !matches.isEmpty else {
            return makeCheck(
                id: "project.protected_path_warning",
                status: .pass,
                message: "Project profile paths are not under known protected paths"
            )
        }
        return makeCheck(
            id: "project.protected_path_warning",
            status: .warn,
            message: "Project profile paths are under protected or high-risk paths: \(matches.joined(separator: "; "))",
            manualAction: "Move repo roots, project/workspace paths, and explicit build output overrides to developer-owned paths"
        )
    }

    private func packageResolutionPreflightCheck(profile: ProjectProfile, schemeAvailable: Bool) throws -> DoctorCheck {
        guard schemeAvailable else {
            return DoctorCheck(
                id: "project.package_resolution_preflight",
                status: .pass,
                message: "Package resolution preflight skipped because the configured scheme is unavailable",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let result = try environment.toolRunner.run(
            tool: "xcodebuild",
            arguments: xcodebuildProjectArguments(for: profile, includeScheme: true) + ["-resolvePackageDependencies"],
            environment: profile.env,
            workingDirectory: profile.workingDirectory,
            timeout: profile.timeouts.build
        )
        guard result.exitCode == 0 else {
            return DoctorCheck(
                id: "project.package_resolution_preflight",
                status: .fail,
                message: "Package dependency resolution failed during project preflight",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcodebuild -resolvePackageDependencies and fix the reported package issues"
            )
        }

        return DoctorCheck(
            id: "project.package_resolution_preflight",
            status: .pass,
            message: "Package dependency resolution preflight succeeded",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func xctestrunIntegrityCheck(profile: ProjectProfile, schemeAvailable: Bool) throws -> DoctorCheck {
        guard schemeAvailable else {
            return makeCheck(
                id: "project.xctestrun_integrity",
                status: .pass,
                message: ".xctestrun integrity check skipped because the configured scheme is unavailable"
            )
        }

        let root = environment.paths.doctorRoot
            .appendingPathComponent("xctestrun-integrity")
            .appendingPathComponent(profile.name)
            .appendingPathComponent(environment.uuidProvider.makeUUID())
        let derivedData = root.appendingPathComponent("DerivedData")
        try environment.fileSystem.createDirectory(root)

        var arguments = xcodebuildProjectArguments(for: profile, includeScheme: true)
        arguments += [
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", derivedData.path,
        ]
        if let testPlan = profile.defaultTestPlan, !testPlan.isEmpty {
            arguments += ["-testPlan", testPlan]
        }
        arguments.append("build-for-testing")

        let buildStartedAt = Date()
        let build: ToolResult
        do {
            build = try environment.toolRunner.run(
                tool: "xcodebuild",
                arguments: arguments,
                environment: profile.env,
                workingDirectory: profile.workingDirectory,
                timeout: profile.timeouts.build
            )
        } catch {
            return xctestrunIntegrityCheckAfterCleanup(
                makeCheck(
                    id: "project.xctestrun_integrity",
                    status: .fail,
                    message: "build-for-testing could not run while validating .xctestrun generation: \(error)",
                    manualAction: "Run xcodebuild build-for-testing for the configured scheme and fix the reported build issue"
                ),
                scratchRoot: root
            )
        }
        guard build.exitCode == 0, !build.timedOut else {
            return xctestrunIntegrityCheckAfterCleanup(
                makeCheck(
                    id: "project.xctestrun_integrity",
                    status: .fail,
                    message: "build-for-testing failed while validating .xctestrun generation",
                    manualAction: "Run xcodebuild build-for-testing for the configured scheme and fix the reported build issue"
                ),
                scratchRoot: root
            )
        }

        let productsRoot = derivedData.appendingPathComponent("Build/Products")
        let xctestrunFiles = findCurrentBuildXCTestRunFiles(under: productsRoot, buildStartedAt: buildStartedAt)
        guard let xctestrun = xctestrunFiles.first else {
            return xctestrunIntegrityCheckAfterCleanup(
                makeCheck(
                    id: "project.xctestrun_integrity",
                    status: .fail,
                    message: "build-for-testing completed but did not produce a current-build .xctestrun file",
                    manualAction: "Inspect \(productsRoot.path) and verify the scheme has test targets enabled for build-for-testing"
                ),
                scratchRoot: root
            )
        }

        return xctestrunIntegrityCheckAfterCleanup(
            makeCheck(
                id: "project.xctestrun_integrity",
                status: .pass,
                message: ".xctestrun generated successfully at \(xctestrun.lastPathComponent)"
            ),
            scratchRoot: root
        )
    }

    private func xcresulttoolCompatibilityCheck() throws -> DoctorCheck {
        let helpResult = try environment.toolRunner.run(
            tool: "xcrun",
            arguments: ["xcresulttool", "help"],
            environment: [:],
            workingDirectory: nil,
            timeout: 10
        )
        guard helpResult.exitCode == 0 else {
            return DoctorCheck(
                id: "project.xcresulttool_compat",
                status: .fail,
                message: "xcresulttool is unavailable from the selected Xcode",
                autoFixable: false,
                fixed: false,
                manualAction: "Ensure xcresulttool is installed and available via xcrun"
            )
        }

        let modernHelpResult = try environment.toolRunner.run(
            tool: "xcrun",
            arguments: ["xcresulttool", "get", "test-results", "summary", "--help"],
            environment: [:],
            workingDirectory: nil,
            timeout: 10
        )
        let exposesModernPath = modernHelpResult.exitCode == 0 &&
            (modernHelpResult.output.contains("xcresulttool get test-results summary") ||
             modernHelpResult.output.localizedCaseInsensitiveContains("test report summary"))
        guard exposesModernPath else {
            return DoctorCheck(
                id: "project.xcresulttool_compat",
                status: .fail,
                message: "xcresulttool does not expose the modern test-results parser path XCSteward expects",
                autoFixable: false,
                fixed: false,
                manualAction: "Use an Xcode version whose xcresulttool supports 'get test-results summary'"
            )
        }

        return DoctorCheck(
            id: "project.xcresulttool_compat",
            status: .pass,
            message: "xcresulttool exposes the modern test-results parser path XCSteward expects",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func developerDirEnvironmentOverrideCheck() throws -> DoctorCheck {
        guard let override = environment.processInfo.environment["DEVELOPER_DIR"],
              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return DoctorCheck(
                id: "global.developer_dir_env_override",
                status: .pass,
                message: "DEVELOPER_DIR is not overriding the selected developer directory",
                autoFixable: true,
                fixed: false,
                manualAction: nil
            )
        }

        let select = try environment.toolRunner.run(
            tool: "xcode-select",
            arguments: ["-p"],
            environment: [:],
            workingDirectory: nil,
            timeout: 10
        )
        guard select.exitCode == 0 else {
            return DoctorCheck(
                id: "global.developer_dir_env_override",
                status: .warn,
                message: "DEVELOPER_DIR is set, but xcode-select -p could not be read for comparison",
                autoFixable: true,
                fixed: false,
                manualAction: "Unset DEVELOPER_DIR or align it with the intended Xcode.app developer directory"
            )
        }

        let normalizedOverride = normalizePath(override)
        let selectedDeveloperDir = normalizePath(select.output)
        if normalizedOverride == selectedDeveloperDir {
            return DoctorCheck(
                id: "global.developer_dir_env_override",
                status: .pass,
                message: "DEVELOPER_DIR matches the selected developer directory",
                autoFixable: true,
                fixed: false,
                manualAction: nil
            )
        }

        return DoctorCheck(
            id: "global.developer_dir_env_override",
            status: .warn,
            message: "DEVELOPER_DIR overrides xcode-select -p with a different developer directory",
            autoFixable: true,
            fixed: false,
            manualAction: "Unset DEVELOPER_DIR or align it with the selected Xcode.app developer directory"
        )
    }

    private func commandLineToolsSelectionCheck() throws -> DoctorCheck {
        let select = try selectedDeveloperDirectory()
        guard select.exitCode == 0 else {
            return DoctorCheck(
                id: "global.clt_vs_xcode_selection",
                status: .fail,
                message: "Unable to read the active developer directory with xcode-select -p",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcode-select -p and ensure a full Xcode.app developer directory is selected"
            )
        }

        let selectedDeveloperDir = normalizePath(select.output)
        if selectedDeveloperDir.contains("/Library/Developer/CommandLineTools") {
            return DoctorCheck(
                id: "global.clt_vs_xcode_selection",
                status: .fail,
                message: "The active developer directory points at Command Line Tools instead of a full Xcode.app",
                autoFixable: false,
                fixed: false,
                manualAction: "Run sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
            )
        }

        return DoctorCheck(
            id: "global.clt_vs_xcode_selection",
            status: .pass,
            message: "The active developer directory points at a full Xcode.app",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func firstLaunchComponentsCheck() throws -> DoctorCheck {
        let select = try selectedDeveloperDirectory()
        guard select.exitCode == 0 else {
            return DoctorCheck(
                id: "global.first_launch_components",
                status: .warn,
                message: "First-launch component check skipped because xcode-select -p could not be read",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcode-select -p, then rerun doctor"
            )
        }

        let selectedDeveloperDir = normalizePath(select.output)
        if selectedDeveloperDir.contains("/Library/Developer/CommandLineTools") {
            return DoctorCheck(
                id: "global.first_launch_components",
                status: .pass,
                message: "First-launch component check skipped because a full Xcode.app is not selected",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let findSimctl = try environment.toolRunner.run(
            tool: "xcrun",
            arguments: ["--find", "simctl"],
            environment: [:],
            workingDirectory: nil,
            timeout: 10
        )
        guard findSimctl.exitCode == 0 else {
            return DoctorCheck(
                id: "global.first_launch_components",
                status: .fail,
                message: "Required first-launch components are missing; simctl is unavailable from the selected Xcode",
                autoFixable: false,
                fixed: false,
                manualAction: "Run sudo xcodebuild -runFirstLaunch and retry"
            )
        }

        return DoctorCheck(
            id: "global.first_launch_components",
            status: .pass,
            message: "First-launch Xcode components are available",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func iPhoneSimulatorSDKPresenceCheck() throws -> DoctorCheck {
        let select = try selectedDeveloperDirectory()
        guard select.exitCode == 0 else {
            return DoctorCheck(
                id: "global.iphonesimulator_sdk_present",
                status: .warn,
                message: "iphonesimulator SDK check skipped because xcode-select -p could not be read",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcode-select -p, then rerun doctor"
            )
        }

        let selectedDeveloperDir = normalizePath(select.output)
        if selectedDeveloperDir.contains("/Library/Developer/CommandLineTools") {
            return DoctorCheck(
                id: "global.iphonesimulator_sdk_present",
                status: .pass,
                message: "iphonesimulator SDK check skipped because a full Xcode.app is not selected",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let showsdks = try environment.toolRunner.run(
            tool: "xcodebuild",
            arguments: ["-showsdks"],
            environment: [:],
            workingDirectory: nil,
            timeout: 20
        )
        if let fallback = bundledIPhoneSimulatorSDKCheck(fromDeveloperDir: selectedDeveloperDir, probe: showsdks) {
            return fallback
        }
        guard showsdks.exitCode == 0 else {
            return DoctorCheck(
                id: "global.iphonesimulator_sdk_present",
                status: .fail,
                message: "Unable to query simulator SDK availability with xcodebuild -showsdks",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcodebuild -showsdks and ensure simulator SDKs are installed for the selected Xcode"
            )
        }
        guard DoctorOutputParsers.showsSDKsOutputExposesIPhoneSimulatorSDK(showsdks.output) else {
            return DoctorCheck(
                id: "global.iphonesimulator_sdk_present",
                status: .fail,
                message: "The selected Xcode does not expose an iphonesimulator SDK",
                autoFixable: false,
                fixed: false,
                manualAction: "Install iOS Simulator platform support for the selected Xcode"
            )
        }

        return DoctorCheck(
            id: "global.iphonesimulator_sdk_present",
            status: .pass,
            message: "The selected Xcode exposes an iphonesimulator SDK",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func bundledIPhoneSimulatorSDKCheck(fromDeveloperDir developerDir: String, probe: ToolResult) -> DoctorCheck? {
        guard bundledIPhoneSimulatorSDKExists(inDeveloperDir: developerDir) else {
            return nil
        }
        guard probe.exitCode != 0 ||
            probe.timedOut ||
            !DoctorOutputParsers.showsSDKsOutputExposesIPhoneSimulatorSDK(probe.output) else {
            return nil
        }

        let detail: String
        if probe.timedOut {
            detail = "after xcodebuild -showsdks timed out"
        } else if probe.exitCode != 0 {
            detail = "after xcodebuild -showsdks failed"
        } else {
            detail = "via the Xcode platform bundle"
        }
        return DoctorCheck(
            id: "global.iphonesimulator_sdk_present",
            status: .pass,
            message: "The selected Xcode exposes an iphonesimulator SDK (\(detail))",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func bundledIPhoneSimulatorSDKExists(inDeveloperDir developerDir: String) -> Bool {
        let sdkRoot = URL(fileURLWithPath: developerDir)
            .appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/SDKs")
        guard environment.fileSystem.fileExists(sdkRoot),
              let entries = try? environment.fileSystem.contentsOfDirectory(sdkRoot) else {
            return false
        }
        return entries.contains {
            let name = $0.lastPathComponent.lowercased()
            return name.hasPrefix("iphonesimulator") && $0.pathExtension == "sdk"
        }
    }

    private func simulatorRuntimeInstalledCheck() throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.simulator_runtime_installed",
            summary: "simulator runtime availability"
        ) {
            return skipped
        }

        let runtimes: [CoreSimulatorRuntimeProbe]
        switch try runSimulatorRuntimesProbe() {
        case .success(let parsedRuntimes):
            runtimes = parsedRuntimes
        case .failure:
            return makeCheck(
                id: "global.simulator_runtime_installed",
                status: .fail,
                message: "Unable to enumerate Simulator runtimes from simctl",
                manualAction: "Run xcrun simctl list runtimes --json and verify Simulator runtimes are installed"
            )
        }

        let hasAvailableIOSRuntime = runtimes.contains { $0.isIOSRuntime && $0.isAvailable }
        guard hasAvailableIOSRuntime else {
            return DoctorCheck(
                id: "global.simulator_runtime_installed",
                status: .fail,
                message: "No available iOS Simulator runtime is installed",
                autoFixable: false,
                fixed: false,
                manualAction: "Install an iOS Simulator runtime for the selected Xcode"
            )
        }

        return DoctorCheck(
            id: "global.simulator_runtime_installed",
            status: .pass,
            message: "At least one available iOS Simulator runtime is installed",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func simulatorRuntimeUnavailableCheck() throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.simulator_runtime_unavailable",
            summary: "unavailable Simulator runtimes"
        ) {
            return skipped
        }

        let runtimes: [CoreSimulatorRuntimeProbe]
        switch try runSimulatorRuntimesProbe() {
        case .success(let parsedRuntimes):
            runtimes = parsedRuntimes
        case .failure:
            return makeCheck(
                id: "global.simulator_runtime_unavailable",
                status: .warn,
                message: "Unable to inspect whether installed Simulator runtimes are unavailable",
                manualAction: "Run xcrun simctl list runtimes --json and inspect unavailable runtimes manually"
            )
        }

        let unavailableIOSRuntimes = runtimes.filter { $0.isIOSRuntime && !$0.isAvailable }
        guard !unavailableIOSRuntimes.isEmpty else {
            return DoctorCheck(
                id: "global.simulator_runtime_unavailable",
                status: .pass,
                message: "No unavailable iOS Simulator runtimes were detected",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let names = unavailableIOSRuntimes
            .map(\.displayName)
            .prefix(3)
            .joined(separator: ", ")
        return DoctorCheck(
            id: "global.simulator_runtime_unavailable",
            status: .warn,
            message: "Installed iOS Simulator runtimes are unavailable: \(names)",
            autoFixable: false,
            fixed: false,
            manualAction: "Reinstall or re-enable the unavailable iOS Simulator runtimes for the selected Xcode"
        )
    }

    private func runtimeDyldCacheStateCheck() throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.runtime_dyld_cache_state",
            summary: "Simulator runtime dyld cache state"
        ) {
            return skipped
        }

        let runtimes: [CoreSimulatorRuntimeProbe]
        switch try runSimulatorRuntimesProbe() {
        case .success(let parsedRuntimes):
            runtimes = parsedRuntimes
        case .failure:
            return makeCheck(
                id: "global.runtime_dyld_cache_state",
                status: .warn,
                message: "Unable to inspect Simulator runtime dyld cache state",
                manualAction: "Run xcrun simctl list runtimes --json and inspect runtime availability errors manually"
            )
        }

        let dyldFailures = runtimes.filter {
            $0.isIOSRuntime && $0.availabilityText.localizedCaseInsensitiveContains("dyld")
        }
        guard !dyldFailures.isEmpty else {
            return makeCheck(
                id: "global.runtime_dyld_cache_state",
                status: .pass,
                message: "No Simulator runtime dyld cache errors were detected"
            )
        }

        let names = dyldFailures
            .map(\.displayName)
            .prefix(3)
            .joined(separator: ", ")
        return makeCheck(
            id: "global.runtime_dyld_cache_state",
            status: .fail,
            message: "Simulator runtimes report dyld cache errors: \(names)",
            manualAction: "Reinstall the affected iOS Simulator runtime or refresh Xcode runtime support before running simulator jobs"
        )
    }

    private func unavailableDevicesCleanupCheck(fixOptions: DoctorFixOptions) throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.unavailable_devices_cleanup",
            summary: "unavailable Simulator device cleanup"
        ) {
            return skipped
        }

        let deviceList: CoreSimulatorDeviceListProbe
        switch try runDecodableJSONProbe(
            CoreSimulatorDeviceListProbe.self,
            tool: "xcrun",
            arguments: ["simctl", "list", "devices", "--json"],
            timeout: 10
        ) {
        case .success(let parsedDeviceList):
            deviceList = parsedDeviceList
        case .failure:
            return makeCheck(
                id: "global.unavailable_devices_cleanup",
                status: .warn,
                message: "Unable to inspect unavailable Simulator devices",
                autoFixable: true,
                manualAction: "Run doctor --fix-global after verifying CoreSimulator can list devices"
            )
        }

        let unavailableDevices = unavailableSimulatorDevices(in: deviceList)
        guard !unavailableDevices.isEmpty else {
            return makeCheck(
                id: "global.unavailable_devices_cleanup",
                status: .pass,
                message: "No unavailable Simulator devices were detected",
                autoFixable: true
            )
        }

        if fixOptions.applyGlobalFixes {
            let delete = try environment.toolRunner.run(
                tool: "xcrun",
                arguments: ["simctl", "delete", "unavailable"],
                environment: [:],
                workingDirectory: nil,
                timeout: 30
            )
            guard delete.exitCode == 0, !delete.timedOut else {
                return makeCheck(
                    id: "global.unavailable_devices_cleanup",
                    status: .fail,
                    message: "Unable to delete unavailable Simulator devices",
                    autoFixable: true,
                    manualAction: "Run xcrun simctl delete unavailable manually and inspect CoreSimulator errors"
                )
            }
            return makeCheck(
                id: "global.unavailable_devices_cleanup",
                status: .pass,
                message: "Deleted \(unavailableDevices.count) unavailable Simulator device\(unavailableDevices.count == 1 ? "" : "s")",
                autoFixable: true,
                fixed: true
            )
        }

        let names = unavailableDevices.prefix(3).joined(separator: ", ")
        return makeCheck(
            id: "global.unavailable_devices_cleanup",
            status: .warn,
            message: "Unavailable Simulator devices were detected: \(names)",
            autoFixable: true,
            manualAction: "Run doctor --fix-global to execute xcrun simctl delete unavailable"
        )
    }

    private func coreSimulatorListJSONHealthCheck() throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.coresim_list_json_health",
            summary: "CoreSimulator JSON enumeration"
        ) {
            return skipped
        }

        switch try runJSONProbe(tool: "xcrun", arguments: ["simctl", "list", "--json"], timeout: 2) {
        case .failure(.timedOut):
            return makeCheck(
                id: "global.coresim_list_json_health",
                status: .fail,
                message: "xcrun simctl list --json timed out while enumerating CoreSimulator state",
                manualAction: "Inspect CoreSimulator health manually and retry once simctl list --json returns promptly"
            )
        case .failure(.nonZeroExit):
            return makeCheck(
                id: "global.coresim_list_json_health",
                status: .fail,
                message: "xcrun simctl list --json failed while enumerating CoreSimulator state",
                manualAction: "Run xcrun simctl list --json manually and inspect CoreSimulator errors"
            )
        case .failure(.invalidJSON):
            return makeCheck(
                id: "global.coresim_list_json_health",
                status: .fail,
                message: "xcrun simctl list --json returned invalid JSON",
                manualAction: "Run xcrun simctl list --json manually and inspect CoreSimulator output"
            )
        case .success:
            return makeCheck(
                id: "global.coresim_list_json_health",
                status: .pass,
                message: "CoreSimulator JSON enumeration is healthy"
            )
        }
    }

    private func concurrentRunnerContentionCheck() throws -> DoctorCheck {
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
            return DoctorCheck(
                id: "global.concurrent_runner_contention",
                status: .warn,
                message: "Unable to determine whether competing local runner processes are active",
                autoFixable: false,
                fixed: false,
                manualAction: "Inspect active xcodebuild, xctest, or simctl processes manually"
            )
        }
        guard processes.exitCode == 0 else {
            return DoctorCheck(
                id: "global.concurrent_runner_contention",
                status: .warn,
                message: "Unable to determine whether competing local runner processes are active",
                autoFixable: false,
                fixed: false,
                manualAction: "Inspect active xcodebuild, xctest, or simctl processes manually"
            )
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

    private func diskPressureWarningCheck() -> DoctorCheck {
        let path = environment.paths.stateRoot.path
        let warnPercent = diskThresholdPercent(
            environmentKey: "XCSTEWARD_DOCTOR_WARN_FREE_PERCENT",
            defaultPercent: 10
        )
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            guard let free = attributes[.systemFreeSize] as? NSNumber,
                  let total = attributes[.systemSize] as? NSNumber,
                  total.int64Value > 0 else {
                return makeCheck(
                    id: "global.disk_pressure_warning",
                    status: .warn,
                    message: "Unable to read disk pressure for the XCSteward state volume",
                    manualAction: "Check available disk capacity manually before running simulator jobs"
                )
            }

            let freePercent = (Double(free.int64Value) / Double(total.int64Value)) * 100
            if freePercent < Double(warnPercent) {
                return makeCheck(
                    id: "global.disk_pressure_warning",
                    status: .warn,
                    message: "Disk pressure is elevated on the XCSteward state volume (\(formatPercent(freePercent)) free)",
                    manualAction: "Free disk space before running parallel simulator jobs; CoreSimulator and result bundles are I/O intensive"
                )
            }
            return makeCheck(
                id: "global.disk_pressure_warning",
                status: .pass,
                message: "Disk pressure is acceptable on the XCSteward state volume (\(formatPercent(freePercent)) free)"
            )
        } catch {
            return makeCheck(
                id: "global.disk_pressure_warning",
                status: .warn,
                message: "Unable to inspect disk pressure for \(path)",
                manualAction: "Check available disk capacity manually before running simulator jobs"
            )
        }
    }

    private func protectedPathWarningCheck() -> DoctorCheck {
        let path = normalizePath(environment.paths.stateRoot.path)
        if let matched = protectedPathPrefix(for: path) {
            return makeCheck(
                id: "global.protected_path_warning",
                status: .warn,
                message: "XCSteward state root is under a protected or high-risk path: \(matched)",
                manualAction: "Move XCSTEWARD_HOME or --state-root to an unprotected developer-owned path such as ~/.xcsteward"
            )
        }
        return makeCheck(
            id: "global.protected_path_warning",
            status: .pass,
            message: "XCSteward state root is not under a known protected path"
        )
    }

    private func xcodeCLIAlignmentCheck() throws -> DoctorCheck {
        let select = try selectedDeveloperDirectory()
        guard select.exitCode == 0 else {
            return DoctorCheck(
                id: "global.xcode_cli_alignment",
                status: .fail,
                message: "Unable to read the selected developer directory with xcode-select -p",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcode-select -p and ensure full Xcode is selected"
            )
        }

        let selectedDeveloperDir = normalizePath(select.output)
        if selectedDeveloperDir.contains("/Library/Developer/CommandLineTools") {
            return DoctorCheck(
                id: "global.xcode_cli_alignment",
                status: .warn,
                message: "xcode CLI alignment check skipped because Command Line Tools is selected instead of a full Xcode.app",
                autoFixable: false,
                fixed: false,
                manualAction: "Run sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
            )
        }

        let found = try environment.toolRunner.run(
            tool: "xcrun",
            arguments: ["--find", "xcodebuild"],
            environment: [:],
            workingDirectory: nil,
            timeout: 10
        )
        guard found.exitCode == 0 else {
            return DoctorCheck(
                id: "global.xcode_cli_alignment",
                status: .fail,
                message: "Unable to resolve xcodebuild with xcrun --find xcodebuild",
                autoFixable: false,
                fixed: false,
                manualAction: "Verify Xcode command line tools are installed and xcrun can resolve xcodebuild"
            )
        }

        let xcodebuildPath = normalizePath(found.output)
        if !xcodebuildPath.hasPrefix(selectedDeveloperDir) {
            return DoctorCheck(
                id: "global.xcode_cli_alignment",
                status: .fail,
                message: "xcodebuild resolves outside the selected developer directory",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcode-select --switch so xcrun and xcodebuild resolve from the same Xcode.app"
            )
        }

        let xcodebuildVersionResult = try environment.toolRunner.run(
            tool: "xcodebuild",
            arguments: ["-version"],
            environment: [:],
            workingDirectory: nil,
            timeout: 10
        )
        guard xcodebuildVersionResult.exitCode == 0 else {
            return DoctorCheck(
                id: "global.xcode_cli_alignment",
                status: .fail,
                message: "Unable to query xcodebuild -version",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcodebuild -version and ensure Xcode is installed and licensed"
            )
        }

        let cliVersion = parseXcodeVersion(from: xcodebuildVersionResult.output)
        if let selectedVersion = try selectedXcodeVersion(fromDeveloperDir: selectedDeveloperDir),
           let cliVersion,
           selectedVersion != cliVersion {
            return DoctorCheck(
                id: "global.xcode_cli_alignment",
                status: .fail,
                message: "Selected Xcode version \(selectedVersion) does not match xcodebuild version \(cliVersion)",
                autoFixable: false,
                fixed: false,
                manualAction: "Run xcode-select --switch to the intended Xcode.app and retry"
            )
        }

        let message: String
        if let cliVersion {
            message = "xcode-select and xcodebuild are aligned on Xcode \(cliVersion)"
        } else {
            message = "xcode-select and xcodebuild resolve from the same developer directory"
        }
        return DoctorCheck(
            id: "global.xcode_cli_alignment",
            status: .pass,
            message: message,
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    private func parseXcodeVersion(from output: String) -> String? {
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("Xcode ") {
                return String(text.dropFirst("Xcode ".count))
            }
        }
        return nil
    }

    private func xcodebuildProjectArguments(for profile: ProjectProfile, includeScheme: Bool) -> [String] {
        var arguments: [String] = []
        if let workspacePath = profile.workspacePath {
            arguments += ["-workspace", workspacePath]
        } else if let projectPath = profile.projectPath {
            arguments += ["-project", projectPath]
        }
        if includeScheme {
            arguments += ["-scheme", profile.scheme]
        }
        return arguments
    }

    private func runSimulatorRuntimesProbe() throws -> Result<[CoreSimulatorRuntimeProbe], DoctorProbeFailure> {
        switch try runDecodableJSONProbe(
            CoreSimulatorRuntimeListProbe.self,
            tool: "xcrun",
            arguments: ["simctl", "list", "runtimes", "--json"],
            timeout: 10
        ) {
        case .success(let probe):
            return .success(probe.runtimes)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func runDecodableJSONProbe<T: Decodable>(
        _ type: T.Type,
        tool: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: TimeInterval
    ) throws -> Result<T, DoctorProbeFailure> {
        let result = try self.environment.toolRunner.run(
            tool: tool,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        if result.timedOut {
            return .failure(.timedOut)
        }
        guard result.exitCode == 0 else {
            return .failure(.nonZeroExit)
        }
        guard let data = result.output.data(using: .utf8) else {
            return .failure(.invalidJSON)
        }
        do {
            return .success(try JSONDecoder().decode(type, from: data))
        } catch {
            return .failure(.invalidJSON)
        }
    }

    private func runJSONProbe(
        tool: String,
        arguments: [String],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: TimeInterval
    ) throws -> Result<[String: Any], DoctorProbeFailure> {
        let result = try self.environment.toolRunner.run(
            tool: tool,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        if result.timedOut {
            return .failure(.timedOut)
        }
        guard result.exitCode == 0 else {
            return .failure(.nonZeroExit)
        }
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        return .success(json)
    }

    private func availableSchemes(from output: String) -> [String] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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

    private func unavailableSimulatorDevices(in probe: CoreSimulatorDeviceListProbe) -> [String] {
        probe.devices.values
            .flatMap { $0 }
            .filter(\.isUnavailable)
            .map(\.displayName)
    }

    private func findXCTestRunFiles(under root: URL) -> [URL] {
        guard let entries = try? environment.fileSystem.contentsOfDirectory(root) else {
            return []
        }
        var matches: [URL] = []
        for entry in entries {
            if entry.pathExtension == "xctestrun" {
                matches.append(entry)
            } else {
                matches.append(contentsOf: findXCTestRunFiles(under: entry))
            }
        }
        return matches.sorted { $0.path < $1.path }
    }

    private func findCurrentBuildXCTestRunFiles(under root: URL, buildStartedAt: Date) -> [URL] {
        findXCTestRunFiles(under: root)
            .filter { xctestrunWasGeneratedByCurrentBuild($0, buildStartedAt: buildStartedAt) }
    }

    private func xctestrunWasGeneratedByCurrentBuild(_ file: URL, buildStartedAt: Date) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]) else {
            return false
        }
        let threshold = buildStartedAt.addingTimeInterval(-1)
        if let contentModificationDate = values.contentModificationDate,
           contentModificationDate >= threshold {
            return true
        }
        return false
    }

    private func xctestrunIntegrityCheckAfterCleanup(_ check: DoctorCheck, scratchRoot: URL) -> DoctorCheck {
        do {
            try environment.fileSystem.removeItem(scratchRoot)
            return check
        } catch {
            let status: DoctorStatus = check.status == .pass ? .warn : check.status
            return makeCheck(
                id: check.id,
                status: status,
                message: "\(check.message); scratch cleanup failed at \(scratchRoot.path): \(error)",
                autoFixable: check.autoFixable,
                fixed: check.fixed,
                manualAction: check.manualAction ?? "Remove stale doctor scratch directory \(scratchRoot.path)"
            )
        }
    }

    private func skippedSimctlDependentCheck(id: String, summary: String) throws -> DoctorCheck? {
        let select = try selectedDeveloperDirectory()
        guard select.exitCode == 0 else {
            return DoctorCheck(
                id: id,
                status: .pass,
                message: "\(summary.capitalized) check skipped because xcode-select -p could not be read",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let selectedDeveloperDir = normalizePath(select.output)
        if selectedDeveloperDir.contains("/Library/Developer/CommandLineTools") {
            return DoctorCheck(
                id: id,
                status: .pass,
                message: "\(summary.capitalized) check skipped because a full Xcode.app is not selected",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let findSimctl = try environment.toolRunner.run(
            tool: "xcrun",
            arguments: ["--find", "simctl"],
            environment: [:],
            workingDirectory: nil,
            timeout: 10
        )
        guard findSimctl.exitCode == 0 else {
            return DoctorCheck(
                id: id,
                status: .pass,
                message: "\(summary.capitalized) check skipped because simctl is unavailable from the selected Xcode",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        return nil
    }

    private func selectedDeveloperDirectory() throws -> ToolResult {
        try environment.toolRunner.run(
            tool: "xcode-select",
            arguments: ["-p"],
            environment: [:],
            workingDirectory: nil,
            timeout: 10
        )
    }

    private func selectedXcodeVersion(fromDeveloperDir developerDir: String) throws -> String? {
        let developerURL = URL(fileURLWithPath: developerDir)
        let versionPlistURL = developerURL.deletingLastPathComponent().appendingPathComponent("version.plist")
        guard environment.fileSystem.fileExists(versionPlistURL) else {
            return nil
        }
        let data = try environment.fileSystem.readData(from: versionPlistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }

    private func diskThresholdBytes(environmentKey: String, defaultBytes: Int64) -> Int64 {
        guard let rawValue = environment.processInfo.environment[environmentKey],
              let parsed = Int64(rawValue),
              parsed >= 0
        else {
            return defaultBytes
        }
        return parsed
    }

    private func diskThresholdPercent(environmentKey: String, defaultPercent: Int) -> Int {
        guard let rawValue = environment.processInfo.environment[environmentKey],
              let parsed = Int(rawValue),
              parsed >= 0
        else {
            return defaultPercent
        }
        return parsed
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func protectedPathPrefix(for path: String) -> String? {
        protectedPathPrefixes().first { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private func protectedProfilePaths(profile: ProjectProfile) -> [ProtectedProfilePath] {
        let repoURL = URL(fileURLWithPath: profile.repoRoot).standardizedFileURL
        var paths = [
            ProtectedProfilePath(label: "repo_root", url: repoURL),
        ]
        if let projectPath = profile.projectPath, !projectPath.isEmpty {
            paths.append(
                ProtectedProfilePath(
                    label: "project_path",
                    url: profilePathURL(projectPath, relativeTo: repoURL)
                )
            )
        }
        if let workspacePath = profile.workspacePath, !workspacePath.isEmpty {
            paths.append(
                ProtectedProfilePath(
                    label: "workspace_path",
                    url: profilePathURL(workspacePath, relativeTo: repoURL)
                )
            )
        }
        for key in ["DERIVED_DATA_PATH", "SYMROOT", "OBJROOT"] {
            guard let rawPath = profile.env[key], !rawPath.isEmpty else {
                continue
            }
            paths.append(
                ProtectedProfilePath(
                    label: key,
                    url: profilePathURL(rawPath, relativeTo: repoURL)
                )
            )
        }
        return paths
    }

    private func profilePathURL(_ path: String, relativeTo baseURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return baseURL.appendingPathComponent(path).standardizedFileURL
    }

    private func protectedPathPrefixes() -> [String] {
        var prefixes = [
            "/Applications",
            "/Library",
            "/System",
            "/bin",
            "/sbin",
            "/usr",
            "/private/var/root",
            "/var/root",
        ]
        if let home = environment.processInfo.environment["HOME"] {
            let normalizedHome = normalizePath(home)
            prefixes += [
                "\(normalizedHome)/Desktop",
                "\(normalizedHome)/Documents",
                "\(normalizedHome)/Downloads",
                "\(normalizedHome)/Library/Mobile Documents",
            ]
        }
        if let extra = environment.processInfo.environment["XCSTEWARD_DOCTOR_PROTECTED_PATHS"] {
            prefixes += extra
                .split(separator: ":")
                .map(String.init)
                .map(normalizePath)
        }
        return prefixes.map(normalizePath)
    }

    private func normalizePath(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}

extension DoctorEngine: SimulatorLifecycleTooling {
    func runTool(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        environmentOverrides: [String: String]
    ) throws -> ToolResult {
        try environment.toolRunner.run(
            tool: tool,
            arguments: arguments,
            environment: context.profile.env.merging(environmentOverrides) { _, override in override },
            workingDirectory: context.profile.workingDirectory,
            timeout: timeout
        )
    }

    func throwIfCanceled(_ result: ToolResult, context: ToolExecutionContext) throws {}

    func commandFailed(_ message: String, output: String) -> XCStewardError {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(detail.isEmpty ? message : "\(message): \(detail)")
    }

    func failAndLog(message: String, exitCode: Int32, logURL: URL, combinedLog: URL) throws -> ToolResult {
        ToolResult(exitCode: exitCode, output: message, timedOut: false)
    }
}
