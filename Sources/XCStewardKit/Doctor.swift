import Foundation

struct DoctorProjectCheckContext {
    let profile: ProjectProfile
    let fixOptions: DoctorFixOptions
    let schemeInspection: DoctorSchemeInspection
    let destinationCheck: DoctorDestinationCheckResult
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

struct DoctorProgressEvent {
    let event: String
    let checkID: String
    let status: String?
}

typealias DoctorProgressHandler = (DoctorProgressEvent) -> Void

final class DoctorEngine {
    private let environment: AppEnvironment
    private let store: StateStore
    private let profileLoader: ProfileLoader

    private var pathSafety: DoctorPathSafety {
        DoctorPathSafety(environment: environment)
    }

    private var stateHealth: DoctorStateHealth {
        DoctorStateHealth(environment: environment, store: store)
    }

    private var diskHealth: DoctorDiskHealth {
        DoctorDiskHealth(environment: environment)
    }

    private var xcodeEnvironment: DoctorXcodeEnvironment {
        DoctorXcodeEnvironment(environment: environment)
    }

    private var coreSimulatorHealth: DoctorCoreSimulatorHealth {
        DoctorCoreSimulatorHealth(environment: environment)
    }

    private var projectPreflight: DoctorProjectPreflight {
        DoctorProjectPreflight(environment: environment, store: store)
    }

    static let globalCheckRegistry: [DoctorGlobalCheckDescriptor] = [
        DoctorGlobalCheckDescriptor(id: "global.state_root") { engine, _ in
            [try engine.stateHealth.stateRootHealthCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.free_disk_space") { engine, _ in
            [engine.diskHealth.freeDiskSpaceCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.developer_dir_env_override") { engine, _ in
            [try engine.xcodeEnvironment.developerDirEnvironmentOverrideCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.clt_vs_xcode_selection") { engine, _ in
            [try engine.xcodeEnvironment.commandLineToolsSelectionCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.first_launch_components") { engine, _ in
            [try engine.xcodeEnvironment.firstLaunchComponentsCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.iphonesimulator_sdk_present") { engine, _ in
            [try engine.xcodeEnvironment.iPhoneSimulatorSDKPresenceCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.iphonesimulator_runtime_compatible") { engine, _ in
            [try engine.coreSimulatorHealth.iPhoneSimulatorRuntimeCompatibilityCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.simulator_runtime_installed") { engine, _ in
            [try engine.coreSimulatorHealth.simulatorRuntimeInstalledCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.simulator_runtime_unavailable") { engine, _ in
            [try engine.coreSimulatorHealth.simulatorRuntimeUnavailableCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.runtime_dyld_cache_state") { engine, _ in
            [try engine.coreSimulatorHealth.runtimeDyldCacheStateCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.unavailable_devices_cleanup") { engine, fixOptions in
            [try engine.coreSimulatorHealth.unavailableDevicesCleanupCheck(fixOptions: fixOptions)]
        },
        DoctorGlobalCheckDescriptor(id: "global.coresim_list_json_health") { engine, _ in
            [try engine.coreSimulatorHealth.coreSimulatorListJSONHealthCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.concurrent_runner_contention") { engine, _ in
            [try engine.stateHealth.concurrentRunnerContentionCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.disk_pressure_warning") { engine, _ in
            [engine.diskHealth.diskPressureWarningCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.protected_path_warning") { engine, _ in
            [engine.pathSafety.protectedPathWarningCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.xcode_cli_alignment") { engine, _ in
            [try engine.xcodeEnvironment.xcodeCLIAlignmentCheck()]
        },
        DoctorGlobalCheckDescriptor(id: "global.worker_lease") { engine, fixOptions in
            [try engine.stateHealth.workerLeaseHealthCheck(fix: fixOptions.applySafeFixes)]
        },
        DoctorGlobalCheckDescriptor(id: "global.simulator_leases") { engine, fixOptions in
            [try engine.stateHealth.simulatorLeaseHealthCheck(fix: fixOptions.applySafeFixes)]
        },
    ]

    static let projectCheckRegistry: [DoctorProjectCheckDescriptor] = [
        DoctorProjectCheckDescriptor(id: "project.repo_root") { engine, context in
            [engine.projectPreflight.repoRootCheck(profile: context.profile)]
        },
        DoctorProjectCheckDescriptor(id: "project.project_path") { engine, context in
            engine.projectPreflight.projectPathCheck(profile: context.profile)
        },
        DoctorProjectCheckDescriptor(id: "project.scheme") { engine, context in
            [engine.projectPreflight.schemeCheck(profile: context.profile, schemeInspection: context.schemeInspection)]
        },
        DoctorProjectCheckDescriptor(id: "project.showdestinations_runnable") { engine, context in
            [context.destinationCheck.check]
        },
        DoctorProjectCheckDescriptor(id: "project.testplan_exists") { engine, context in
            [try engine.projectPreflight.configuredTestPlanCheck(profile: context.profile, schemeInspection: context.schemeInspection)]
        },
        DoctorProjectCheckDescriptor(id: "project.derived_data_isolation") { engine, context in
            [engine.projectPreflight.derivedDataIsolationCheck(profile: context.profile)]
        },
        DoctorProjectCheckDescriptor(id: "project.protected_path_warning") { engine, context in
            [engine.pathSafety.projectProtectedPathWarningCheck(profile: context.profile)]
        },
        DoctorProjectCheckDescriptor(id: "project.xcode_managed_parallel_workers") { engine, context in
            [engine.projectPreflight.parallelCloneRiskCheck(profile: context.profile)]
        },
        DoctorProjectCheckDescriptor(id: "project.package_resolution_preflight") { engine, context in
            [try engine.projectPreflight.packageResolutionPreflightCheck(profile: context.profile, schemeInspection: context.schemeInspection)]
        },
        DoctorProjectCheckDescriptor(id: "project.xctestrun_integrity") { engine, context in
            [try engine.projectPreflight.xctestrunIntegrityCheck(
                profile: context.profile,
                schemeInspection: context.schemeInspection,
                runnableIOSSimulatorDestinationAvailable: context.destinationCheck.runnableIOSSimulatorDestinationAvailable,
                concreteIOSSimulatorDestinationSpecifier: context.destinationCheck.concreteIOSSimulatorDestinationSpecifier
            )]
        },
        DoctorProjectCheckDescriptor(id: "project.xcresulttool_compat") { engine, _ in
            [try engine.projectPreflight.xcresulttoolCompatibilityCheck()]
        },
        DoctorProjectCheckDescriptor(id: "project.default_simulator_bootstatus") { engine, context in
            guard let simulatorID = context.profile.defaultSimulatorID else {
                return []
            }
            return [try engine.projectPreflight.configuredSimulatorBootstatusCheck(profile: context.profile, simulatorID: simulatorID)]
        },
        DoctorProjectCheckDescriptor(id: "project.managed_simulator") { engine, context in
            try engine.projectPreflight.managedSimulatorCheck(profile: context.profile, fix: context.fixOptions.applySafeFixes)
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

    func run(
        project: String?,
        fixOptions: DoctorFixOptions,
        progress: DoctorProgressHandler? = nil
    ) throws -> DoctorReport {
        var checks = try runGlobalChecks(fixOptions: fixOptions, progress: progress)

        if let project {
            progress?(DoctorProgressEvent(event: "doctor_check_started", checkID: "project.profile_load", status: nil))
            let profile: ProjectProfile
            do {
                profile = try profileLoader.loadProfile(named: project)
                progress?(DoctorProgressEvent(event: "doctor_check_finished", checkID: "project.profile_load", status: "pass"))
            } catch {
                progress?(DoctorProgressEvent(event: "doctor_check_finished", checkID: "project.profile_load", status: "error"))
                throw error
            }
            checks.append(contentsOf: try projectChecks(profile: profile, fixOptions: fixOptions, progress: progress))
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

    private func runGlobalChecks(
        fixOptions: DoctorFixOptions,
        progress: DoctorProgressHandler?
    ) throws -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        for descriptor in Self.globalCheckRegistry {
            progress?(DoctorProgressEvent(event: "doctor_check_started", checkID: descriptor.id, status: nil))
            do {
                let producedChecks = try descriptor.run(self, fixOptions)
                progress?(DoctorProgressEvent(
                    event: "doctor_check_finished",
                    checkID: descriptor.id,
                    status: progressStatus(for: producedChecks)
                ))
                checks.append(contentsOf: producedChecks)
            } catch {
                progress?(DoctorProgressEvent(event: "doctor_check_finished", checkID: descriptor.id, status: "error"))
                throw error
            }
        }
        return checks
    }

    private func projectChecks(
        profile: ProjectProfile,
        fixOptions: DoctorFixOptions,
        progress: DoctorProgressHandler?
    ) throws -> [DoctorCheck] {
        progress?(DoctorProgressEvent(event: "doctor_check_started", checkID: "project.preflight_context", status: nil))
        let schemeInspection: DoctorSchemeInspection
        let destinationCheck: DoctorDestinationCheckResult
        do {
            schemeInspection = projectPreflight.inspectSchemeAvailability(profile: profile)
            destinationCheck = try projectPreflight.showDestinationsRunnableCheckResult(
                profile: profile,
                schemeInspection: schemeInspection
            )
            progress?(DoctorProgressEvent(event: "doctor_check_finished", checkID: "project.preflight_context", status: "pass"))
        } catch {
            progress?(DoctorProgressEvent(event: "doctor_check_finished", checkID: "project.preflight_context", status: "error"))
            throw error
        }
        let context = DoctorProjectCheckContext(
            profile: profile,
            fixOptions: fixOptions,
            schemeInspection: schemeInspection,
            destinationCheck: destinationCheck
        )
        var checks: [DoctorCheck] = []
        for descriptor in Self.projectCheckRegistry {
            progress?(DoctorProgressEvent(event: "doctor_check_started", checkID: descriptor.id, status: nil))
            do {
                let producedChecks = try descriptor.run(self, context)
                progress?(DoctorProgressEvent(
                    event: "doctor_check_finished",
                    checkID: descriptor.id,
                    status: progressStatus(for: producedChecks)
                ))
                checks.append(contentsOf: producedChecks)
            } catch {
                progress?(DoctorProgressEvent(event: "doctor_check_finished", checkID: descriptor.id, status: "error"))
                throw error
            }
        }
        return checks
    }

    private func progressStatus(for checks: [DoctorCheck]) -> String {
        if checks.isEmpty {
            return "skipped"
        }
        if checks.contains(where: { $0.status == .fail }) {
            return DoctorStatus.fail.rawValue
        }
        if checks.contains(where: { $0.status == .warn }) {
            return DoctorStatus.warn.rawValue
        }
        return DoctorStatus.pass.rawValue
    }

}
