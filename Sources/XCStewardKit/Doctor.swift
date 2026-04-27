import Foundation

private enum DoctorProbeFailure: Error {
    case timedOut
    case nonZeroExit
    case invalidJSON
}

final class DoctorEngine {
    private let environment: AppEnvironment
    private let store: StateStore
    private let profileLoader: ProfileLoader

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

    func run(project: String?, fix: Bool) throws -> DoctorReport {
        var checks: [DoctorCheck] = []

        do {
            try environment.fileSystem.createDirectory(environment.paths.stateRoot)
            checks.append(DoctorCheck(id: "global.state_root", status: .pass, message: "State root is available", autoFixable: false, fixed: false, manualAction: nil))
        } catch {
            checks.append(DoctorCheck(id: "global.state_root", status: .fail, message: "State root is unavailable", autoFixable: true, fixed: false, manualAction: "Create a writable state root"))
        }

        checks.append(try developerDirEnvironmentOverrideCheck())
        checks.append(try commandLineToolsSelectionCheck())
        checks.append(try firstLaunchComponentsCheck())
        checks.append(try iPhoneSimulatorSDKPresenceCheck())
        checks.append(try simulatorRuntimeInstalledCheck())
        checks.append(try simulatorRuntimeUnavailableCheck())
        checks.append(try coreSimulatorListJSONHealthCheck())
        checks.append(try concurrentRunnerContentionCheck())
        checks.append(try xcodeCLIAlignmentCheck())

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
            checks.append(DoctorCheck(id: "global.worker_lease", status: .pass, message: "Recovered stale worker lease", autoFixable: true, fixed: true, manualAction: nil))
        } else if let lease = try store.currentLease(), !isPIDAlive(lease.pid) {
            checks.append(DoctorCheck(id: "global.worker_lease", status: .fail, message: "Stale worker lease detected", autoFixable: true, fixed: false, manualAction: "Run doctor --fix"))
        } else if environment.fileSystem.fileExists(environment.paths.stateRoot.appendingPathComponent("stale-lease.json")) {
            checks.append(DoctorCheck(id: "global.worker_lease", status: .fail, message: "Legacy stale lease marker detected", autoFixable: true, fixed: false, manualAction: "Run doctor --fix"))
        } else {
            checks.append(DoctorCheck(id: "global.worker_lease", status: .pass, message: "No stale worker lease detected", autoFixable: false, fixed: false, manualAction: nil))
        }

        if let project {
            let profile = try profileLoader.loadProfile(named: project)
            checks.append(contentsOf: try projectChecks(profile: profile, fix: fix))
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

    private func projectChecks(profile: ProjectProfile, fix: Bool) throws -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let repoURL = URL(fileURLWithPath: profile.repoRoot)
        if environment.fileSystem.fileExists(URL(fileURLWithPath: profile.repoRoot)) {
            checks.append(DoctorCheck(id: "project.repo_root", status: .pass, message: "Repo root exists", autoFixable: false, fixed: false, manualAction: nil))
        } else {
            checks.append(DoctorCheck(id: "project.repo_root", status: .fail, message: "Repo root is missing", autoFixable: false, fixed: false, manualAction: "Restore the repository at \(profile.repoRoot)"))
        }
        if let projectPath = profile.projectPath, environment.fileSystem.fileExists(repoURL.appendingPathComponent(projectPath)) {
            checks.append(DoctorCheck(id: "project.project_path", status: .pass, message: "Project path exists", autoFixable: false, fixed: false, manualAction: nil))
        }
        let schemes = try environment.toolRunner.run(
            tool: "xcodebuild",
            arguments: xcodebuildProjectArguments(for: profile, includeScheme: false) + ["-list", "-json"],
            environment: profile.env,
            workingDirectory: profile.workingDirectory,
            timeout: profile.timeouts.build
        )
        let schemeAvailable = schemes.exitCode == 0 &&
            availableSchemes(from: schemes.output).contains(profile.scheme)
        if schemeAvailable {
            checks.append(DoctorCheck(id: "project.scheme", status: .pass, message: "Scheme is available", autoFixable: false, fixed: false, manualAction: nil))
        } else {
            checks.append(DoctorCheck(id: "project.scheme", status: .fail, message: "Scheme is missing", autoFixable: false, fixed: false, manualAction: "Regenerate or share the expected scheme"))
        }
        checks.append(try showDestinationsRunnableCheck(profile: profile, schemeAvailable: schemeAvailable))
        checks.append(try configuredTestPlanCheck(profile: profile, schemeAvailable: schemeAvailable))
        checks.append(derivedDataIsolationCheck(profile: profile))
        checks.append(try packageResolutionPreflightCheck(profile: profile, schemeAvailable: schemeAvailable))
        checks.append(try xcresulttoolCompatibilityCheck())
        if let defaultSimulatorID = profile.defaultSimulatorID {
            checks.append(try configuredSimulatorBootstatusCheck(profile: profile, simulatorID: defaultSimulatorID))
        }
        if let managed = profile.managedSimulator {
            let list = try environment.toolRunner.run(tool: "xcrun", arguments: ["simctl", "list", "devices"], environment: profile.env, workingDirectory: profile.workingDirectory, timeout: profile.timeouts.boot)
            if list.output.contains(managed.name) || list.output.contains(profile.defaultSimulatorID ?? "") {
                checks.append(DoctorCheck(id: "project.managed_simulator", status: .pass, message: "Managed simulator exists", autoFixable: true, fixed: false, manualAction: nil))
            } else if fix {
                let create = try environment.toolRunner.run(tool: "xcrun", arguments: ["simctl", "create", managed.name, managed.deviceType, managed.runtime], environment: profile.env, workingDirectory: profile.workingDirectory, timeout: profile.timeouts.boot)
                let fixed = create.exitCode == 0
                checks.append(DoctorCheck(id: "project.managed_simulator", status: fixed ? .pass : .fail, message: fixed ? "Managed simulator created" : "Unable to create managed simulator", autoFixable: true, fixed: fixed, manualAction: fixed ? nil : "Create the simulator manually"))
            } else {
                checks.append(DoctorCheck(id: "project.managed_simulator", status: .fail, message: "Managed simulator is missing", autoFixable: true, fixed: false, manualAction: "Run doctor --fix"))
            }
        }
        return checks
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
        guard result.output.contains("platform:iOS Simulator") else {
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
        guard showsdks.output.contains("iphonesimulator") else {
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
        guard probe.exitCode != 0 || probe.timedOut || !probe.output.contains("iphonesimulator") else {
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

        let runtimes: [[String: Any]]
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

        let hasAvailableIOSRuntime = runtimes.contains(where: { isIOSRuntime($0) && isAvailableRuntime($0) })
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

        let runtimes: [[String: Any]]
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

        let unavailableIOSRuntimes = runtimes.filter { isIOSRuntime($0) && !isAvailableRuntime($0) }
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
            .compactMap { $0["name"] as? String }
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

    private func runSimulatorRuntimesProbe() throws -> Result<[[String: Any]], DoctorProbeFailure> {
        switch try runJSONProbe(tool: "xcrun", arguments: ["simctl", "list", "runtimes", "--json"], timeout: 10) {
        case .success(let json):
            guard let runtimes = json["runtimes"] as? [[String: Any]] else {
                return .failure(.invalidJSON)
            }
            return .success(runtimes)
        case .failure(let failure):
            return .failure(failure)
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

    private func isIOSRuntime(_ runtime: [String: Any]) -> Bool {
        if let identifier = runtime["identifier"] as? String, identifier.contains(".iOS-") {
            return true
        }
        if let name = runtime["name"] as? String, name.hasPrefix("iOS") {
            return true
        }
        return false
    }

    private func isAvailableRuntime(_ runtime: [String: Any]) -> Bool {
        runtime["isAvailable"] as? Bool == true
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

    private func normalizePath(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
