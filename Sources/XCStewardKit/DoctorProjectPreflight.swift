// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct DoctorDestinationCheckResult {
    var check: DoctorCheck
    var runnableIOSSimulatorDestinationAvailable: Bool
    var concreteIOSSimulatorDestinationSpecifier: String?
}

enum DoctorSchemeInspection {
    case available([String])
    case missing([String])
    case unavailable(DoctorSchemeInspectionFailure)

    var isAvailable: Bool {
        if case .available = self {
            return true
        }
        return false
    }

    var skipReason: String {
        switch self {
        case .available:
            return ""
        case .missing:
            return "the configured scheme is missing"
        case .unavailable:
            return "scheme availability could not be verified"
        }
    }
}

struct DoctorSchemeInspectionFailure {
    let command: String
    let exitCode: Int32?
    let timedOut: Bool
    let output: String

    var diagnosticMessage: String {
        let outcome: String
        if timedOut {
            outcome = "timed out"
        } else if let exitCode {
            outcome = "failed with exit \(exitCode)"
        } else {
            outcome = "could not be started"
        }

        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "Scheme validation skipped because \(command) \(outcome)"
        }
        return "Scheme validation skipped because \(command) \(outcome): \(detail.truncatedForDoctorMessage())"
    }
}

final class DoctorProjectPreflight {
    let environment: AppEnvironment
    let store: StateStore
    private let coreSimulatorHealth: DoctorCoreSimulatorHealth

    init(environment: AppEnvironment, store: StateStore) {
        self.environment = environment
        self.store = store
        coreSimulatorHealth = DoctorCoreSimulatorHealth(environment: environment)
    }

    func repoRootCheck(profile: ProjectProfile) -> DoctorCheck {
        if environment.fileSystem.fileExists(URL(fileURLWithPath: profile.repoRoot)) {
            return DoctorCheck(id: "project.repo_root", status: .pass, message: "Repo root exists", autoFixable: false, fixed: false, manualAction: nil)
        }
        return DoctorCheck(id: "project.repo_root", status: .fail, message: "Repo root is missing", autoFixable: false, fixed: false, manualAction: "Restore the repository at \(profile.repoRoot)")
    }

    func projectPathCheck(profile: ProjectProfile) -> [DoctorCheck] {
        let repoURL = URL(fileURLWithPath: profile.repoRoot)
        if let projectPath = profile.projectPath, environment.fileSystem.fileExists(repoURL.appendingPathComponent(projectPath)) {
            return [DoctorCheck(id: "project.project_path", status: .pass, message: "Project path exists", autoFixable: false, fixed: false, manualAction: nil)]
        }
        return []
    }

    func inspectSchemeAvailability(profile: ProjectProfile) -> DoctorSchemeInspection {
        let arguments = xcodebuildProjectArguments(for: profile, includeScheme: false) + ["-list", "-json"]
        let command = commandLine(tool: "xcodebuild", arguments: arguments)
        let schemes: ToolResult
        do {
            schemes = try environment.toolRunner.run(
                tool: "xcodebuild",
                arguments: arguments,
                environment: profile.env,
                workingDirectory: profile.workingDirectory,
                timeout: profile.timeouts.build
            )
        } catch {
            return .unavailable(DoctorSchemeInspectionFailure(
                command: command,
                exitCode: nil,
                timedOut: false,
                output: String(describing: error)
            ))
        }
        guard schemes.exitCode == 0, !schemes.timedOut else {
            return .unavailable(DoctorSchemeInspectionFailure(
                command: command,
                exitCode: schemes.exitCode,
                timedOut: schemes.timedOut,
                output: schemes.output
            ))
        }

        let availableSchemes = availableSchemes(from: schemes.output)
        if availableSchemes.contains(profile.scheme) {
            return .available(availableSchemes)
        }
        return .missing(availableSchemes)
    }

    func schemeCheck(profile: ProjectProfile, schemeInspection: DoctorSchemeInspection) -> DoctorCheck {
        switch schemeInspection {
        case .available:
            return DoctorCheck(id: "project.scheme", status: .pass, message: "Scheme is available", autoFixable: false, fixed: false, manualAction: nil)
        case .missing:
            return DoctorCheck(id: "project.scheme", status: .fail, message: "Scheme is missing", autoFixable: false, fixed: false, manualAction: "Regenerate or share the expected scheme")
        case .unavailable(let failure):
            return DoctorCheck(
                id: "project.scheme",
                status: .warn,
                message: failure.diagnosticMessage,
                autoFixable: false,
                fixed: false,
                manualAction: "Run the listed xcodebuild command outside the current sandbox and fix project or toolchain access before rerunning doctor"
            )
        }
    }

    func managedSimulatorCheck(profile: ProjectProfile, fix: Bool) throws -> [DoctorCheck] {
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
                let detail = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail.isEmpty
                    ? "Unable to create managed simulator"
                    : "Unable to create managed simulator: \(detail)"
                return [DoctorCheck(id: "project.managed_simulator", status: .fail, message: message, autoFixable: true, fixed: false, manualAction: "Inspect the managed_simulator device_type/runtime values and CoreSimulator runtime availability, then rerun doctor --fix")]
            }
        }
        return [DoctorCheck(id: "project.managed_simulator", status: .fail, message: "Managed simulator is missing", autoFixable: true, fixed: false, manualAction: "Run doctor --fix")]
    }

    func parallelCloneRiskCheck(profile: ProjectProfile) -> DoctorCheck {
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

    func configuredSimulatorBootstatusCheck(profile: ProjectProfile, simulatorID: String) throws -> DoctorCheck {
        if let skipped = try coreSimulatorHealth.skippedSimctlDependentCheck(
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

    func showDestinationsRunnableCheckResult(profile: ProjectProfile, schemeInspection: DoctorSchemeInspection) throws -> DoctorDestinationCheckResult {
        guard schemeInspection.isAvailable else {
            return DoctorDestinationCheckResult(
                check: DoctorCheck(
                    id: "project.showdestinations_runnable",
                    status: .pass,
                    message: "Destination check skipped because \(schemeInspection.skipReason)",
                    autoFixable: false,
                    fixed: false,
                    manualAction: nil
                ),
                runnableIOSSimulatorDestinationAvailable: false,
                concreteIOSSimulatorDestinationSpecifier: nil
            )
        }

        let showDestinationsArguments = xcodebuildProjectArguments(for: profile, includeScheme: true) + ["-showdestinations"]
        var result = try environment.toolRunner.run(
            tool: "xcodebuild",
            arguments: showDestinationsArguments,
            environment: profile.env,
            workingDirectory: profile.workingDirectory,
            timeout: profile.timeouts.build
        )
        let retriedAfterPlaceholderOnlyOutput = result.exitCode == 0 &&
            !DoctorOutputParsers.showDestinationsOutputExposesIOSSimulator(result.output) &&
            DoctorOutputParsers.showDestinationsOutputExposesOnlyIOSSimulatorPlaceholder(result.output)
        if retriedAfterPlaceholderOnlyOutput {
            result = try environment.toolRunner.run(
                tool: "xcodebuild",
                arguments: showDestinationsArguments,
                environment: profile.env,
                workingDirectory: profile.workingDirectory,
                timeout: profile.timeouts.build
            )
        }
        guard result.exitCode == 0 else {
            return DoctorDestinationCheckResult(
                check: DoctorCheck(
                    id: "project.showdestinations_runnable",
                    status: .fail,
                    message: "Unable to inspect runnable destinations for the configured scheme",
                    autoFixable: false,
                    fixed: false,
                    manualAction: "Run xcodebuild -showdestinations for the configured project and scheme"
                ),
                runnableIOSSimulatorDestinationAvailable: false,
                concreteIOSSimulatorDestinationSpecifier: nil
            )
        }
        guard DoctorOutputParsers.showDestinationsOutputExposesIOSSimulator(result.output) else {
            if DoctorOutputParsers.showDestinationsOutputExposesOnlyIOSSimulatorPlaceholder(result.output) {
                return DoctorDestinationCheckResult(
                    check: DoctorCheck(
                        id: "project.showdestinations_runnable",
                        status: .fail,
                        message: "Xcode exposed only the iOS Simulator placeholder for the configured scheme, not a concrete runnable simulator",
                        autoFixable: false,
                        fixed: false,
                        manualAction: "Rerun xcodebuild -showdestinations and xcrun simctl list devices --json; if CoreSimulator lists available devices, refresh Xcode/CoreSimulator destination state or boot/create the configured simulator before rerunning doctor"
                    ),
                    runnableIOSSimulatorDestinationAvailable: false,
                    concreteIOSSimulatorDestinationSpecifier: nil
                )
            }
            return DoctorDestinationCheckResult(
                check: DoctorCheck(
                    id: "project.showdestinations_runnable",
                    status: .fail,
                    message: "The configured scheme does not expose a runnable iOS Simulator destination",
                    autoFixable: false,
                    fixed: false,
                    manualAction: "Adjust the scheme or destination settings until an iOS Simulator destination is runnable"
                ),
                runnableIOSSimulatorDestinationAvailable: false,
                concreteIOSSimulatorDestinationSpecifier: nil
            )
        }

        return DoctorDestinationCheckResult(
            check: DoctorCheck(
                id: "project.showdestinations_runnable",
                status: .pass,
                message: retriedAfterPlaceholderOnlyOutput
                    ? "The configured scheme exposes a runnable iOS Simulator destination after retrying transient placeholder-only output"
                    : "The configured scheme exposes a runnable iOS Simulator destination",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            ),
            runnableIOSSimulatorDestinationAvailable: true,
            concreteIOSSimulatorDestinationSpecifier: DoctorOutputParsers.firstConcreteIOSSimulatorDestinationSpecifier(from: result.output)
        )
    }

    func configuredTestPlanCheck(profile: ProjectProfile, schemeInspection: DoctorSchemeInspection) throws -> DoctorCheck {
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
        guard schemeInspection.isAvailable else {
            return DoctorCheck(
                id: "project.testplan_exists",
                status: .pass,
                message: "Test plan check skipped because \(schemeInspection.skipReason)",
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

    func derivedDataIsolationCheck(profile: ProjectProfile) -> DoctorCheck {
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

    func packageResolutionPreflightCheck(profile: ProjectProfile, schemeInspection: DoctorSchemeInspection) throws -> DoctorCheck {
        guard schemeInspection.isAvailable else {
            return DoctorCheck(
                id: "project.package_resolution_preflight",
                status: .pass,
                message: "Package resolution preflight skipped because \(schemeInspection.skipReason)",
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

    func xctestrunIntegrityCheck(
        profile: ProjectProfile,
        schemeInspection: DoctorSchemeInspection,
        runnableIOSSimulatorDestinationAvailable: Bool,
        concreteIOSSimulatorDestinationSpecifier: String?
    ) throws -> DoctorCheck {
        guard schemeInspection.isAvailable else {
            return makeCheck(
                id: "project.xctestrun_integrity",
                status: .pass,
                message: ".xctestrun integrity check skipped because \(schemeInspection.skipReason)"
            )
        }
        guard runnableIOSSimulatorDestinationAvailable else {
            return makeCheck(
                id: "project.xctestrun_integrity",
                status: .pass,
                message: ".xctestrun integrity check skipped because no concrete runnable iOS Simulator destination is exposed"
            )
        }

        let root = environment.paths.doctorRoot
            .appendingPathComponent("xctestrun-integrity")
            .appendingPathComponent(profile.name)
            .appendingPathComponent(environment.uuidProvider.makeUUID())
        let evidenceRoot = root.deletingLastPathComponent()
        let derivedData = root.appendingPathComponent("DerivedData")
        try environment.fileSystem.createDirectory(root)

        var arguments = xcodebuildProjectArguments(for: profile, includeScheme: true)
        arguments += [
            "-destination", concreteIOSSimulatorDestinationSpecifier ?? "generic/platform=iOS Simulator",
            "-derivedDataPath", derivedData.path,
        ]
        if let testPlan = profile.defaultTestPlan, !testPlan.isEmpty {
            arguments += ["-testPlan", testPlan]
        }
        arguments.append("COMPILER_INDEX_STORE_ENABLE=NO")
        arguments.append("build-for-testing")

        let buildStartedAt = Date()
        let buildProbeTimeout = doctorBuildProbeTimeout(profile)
        let build: ToolResult
        do {
            build = try environment.toolRunner.run(
                tool: "xcodebuild",
                arguments: arguments,
                environment: profile.env,
                workingDirectory: profile.workingDirectory,
                timeout: buildProbeTimeout
            )
        } catch {
            let evidence = try? writeXCTestRunIntegrityEvidence(
                profile: profile,
                evidenceRoot: evidenceRoot,
                runID: root.lastPathComponent,
                arguments: arguments,
                timeout: buildProbeTimeout,
                exitCode: nil,
                timedOut: false,
                output: String(describing: error)
            )
            return xctestrunIntegrityCheckAfterCleanup(
                makeCheck(
                    id: "project.xctestrun_integrity",
                    status: .fail,
                    message: "build-for-testing could not run while validating .xctestrun generation: \(error)",
                    manualAction: "Inspect the retained build-for-testing evidence and fix the reported project or toolchain issue",
                    evidencePath: evidence?.path,
                    failureExcerpt: evidence?.excerpt
                ),
                scratchRoot: root
            )
        }
        if build.timedOut {
            let evidence = try? writeXCTestRunIntegrityEvidence(
                profile: profile,
                evidenceRoot: evidenceRoot,
                runID: root.lastPathComponent,
                arguments: arguments,
                timeout: buildProbeTimeout,
                exitCode: build.exitCode,
                timedOut: true,
                output: build.output
            )
            let compilerNote = buildOutputShowsCompilerError(build.output)
                ? ""
                : "; no compiler error was observed before timeout"
            return xctestrunIntegrityCheckAfterCleanup(
                makeCheck(
                    id: "project.xctestrun_integrity",
                    status: .warn,
                    message: "build-for-testing timed out after \(formattedSeconds(buildProbeTimeout)) while validating .xctestrun generation\(compilerNote)",
                    manualAction: "Inspect the retained build-for-testing evidence when you need full preflight assurance; XCSteward submit will still run with the normal build timeout and preserve job artifacts",
                    evidencePath: evidence?.path,
                    failureExcerpt: evidence?.excerpt
                ),
                scratchRoot: root
            )
        }
        guard build.exitCode == 0 else {
            let evidence = try? writeXCTestRunIntegrityEvidence(
                profile: profile,
                evidenceRoot: evidenceRoot,
                runID: root.lastPathComponent,
                arguments: arguments,
                timeout: buildProbeTimeout,
                exitCode: build.exitCode,
                timedOut: false,
                output: build.output
            )
            return xctestrunIntegrityCheckAfterCleanup(
                makeCheck(
                    id: "project.xctestrun_integrity",
                    status: .fail,
                    message: "build-for-testing failed while validating .xctestrun generation; see retained evidence at \(evidence?.path ?? evidenceRoot.path)",
                    manualAction: "Inspect the retained build-for-testing evidence and fix the reported project or toolchain issue",
                    evidencePath: evidence?.path,
                    failureExcerpt: evidence?.excerpt
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

    func xcresulttoolCompatibilityCheck() throws -> DoctorCheck {
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

    private func doctorBuildProbeTimeout(_ profile: ProjectProfile) -> TimeInterval {
        min(profile.timeouts.build, max(60, profile.timeouts.build * 0.25))
    }

    private func formattedSeconds(_ timeout: TimeInterval) -> String {
        "\(Int(timeout.rounded()))s"
    }

    private func simulatorLine(from output: String, simulatorID: String) -> String? {
        output
            .split(separator: "\n")
            .map(String.init)
            .first { $0.contains("(\(simulatorID))") }
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

    private func commandLine(tool: String, arguments: [String]) -> String {
        ([tool] + arguments).map(shellQuoted).joined(separator: " ")
    }

    private func shellQuoted(_ value: String) -> String {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || value.contains("'") else {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func availableSchemes(from output: String) -> [String] {
        guard let json = jsonObject(from: output) else {
            return output
                .split(separator: "\n")
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\","))
                }
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
            try removeXCTestRunIntegrityScratch(scratchRoot)
            return check
        } catch {
            let status: DoctorStatus = check.status == .pass ? .warn : check.status
            return makeCheck(
                id: check.id,
                status: status,
                message: "\(check.message); scratch cleanup failed at \(scratchRoot.path): \(error)",
                autoFixable: check.autoFixable,
                fixed: check.fixed,
                manualAction: check.manualAction ?? "Remove stale doctor scratch directory \(scratchRoot.path)",
                evidencePath: check.evidencePath,
                failureExcerpt: check.failureExcerpt
            )
        }
    }

    private func removeXCTestRunIntegrityScratch(_ scratchRoot: URL) throws {
        var lastError: Error?
        for attempt in 1...5 {
            do {
                try environment.fileSystem.removeItem(scratchRoot)
                return
            } catch {
                lastError = error
                if attempt < 5 {
                    Thread.sleep(forTimeInterval: TimeInterval(attempt) * 0.25)
                }
            }
        }
        throw lastError ?? XCStewardError.commandFailed("Unable to remove doctor scratch directory \(scratchRoot.path)")
    }

    private func makeCheck(
        id: String,
        status: DoctorStatus,
        message: String,
        autoFixable: Bool = false,
        fixed: Bool = false,
        manualAction: String? = nil,
        evidencePath: String? = nil,
        failureExcerpt: String? = nil
    ) -> DoctorCheck {
        var check = DoctorCheck(
            id: id,
            status: status,
            message: message,
            autoFixable: autoFixable,
            fixed: fixed,
            manualAction: manualAction
        )
        check.evidencePath = evidencePath
        check.failureExcerpt = failureExcerpt
        return check
    }

    private struct XCTestRunIntegrityEvidence {
        let path: String
        let excerpt: String?
    }

    private func writeXCTestRunIntegrityEvidence(
        profile: ProjectProfile,
        evidenceRoot: URL,
        runID: String,
        arguments: [String],
        timeout: TimeInterval,
        exitCode: Int32?,
        timedOut: Bool,
        output: String
    ) throws -> XCTestRunIntegrityEvidence {
        let excerpt = doctorFailureExcerpt(from: output)
        let evidence = evidenceRoot.appendingPathComponent("\(runID)-build-for-testing.log")
        let contents = [
            "tool: xcodebuild",
            "command: \(commandLine(tool: "xcodebuild", arguments: arguments))",
            "working_directory: \(profile.workingDirectory.path)",
            "timeout_seconds: \(formattedSeconds(timeout))",
            "exit_code: \(exitCode.map(String.init) ?? "not_started")",
            "timed_out: \(timedOut)",
            "",
            "output:",
            cappedDoctorEvidence(output)
        ].joined(separator: "\n")
        try environment.fileSystem.writeData(Data(contents.utf8), to: evidence)
        return XCTestRunIntegrityEvidence(path: evidence.path, excerpt: excerpt)
    }

    private func cappedDoctorEvidence(_ output: String, limit: Int = 16_384) -> String {
        guard output.count > limit else {
            return output
        }
        let start = output.index(output.endIndex, offsetBy: -limit)
        return "[output truncated to last \(limit) characters]\n\(output[start...])"
    }

    private func doctorFailureExcerpt(from output: String, limit: Int = 500) -> String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return nil
        }
        let interestingMarkers = ["error:", "fatal error:", "BUILD FAILED", "The following build commands failed"]
        guard let interesting = lines.first(where: { line in
            interestingMarkers.contains { marker in
                line.localizedCaseInsensitiveContains(marker)
            }
        }) ?? lines.last else {
            return nil
        }
        return interesting.truncatedForDoctorMessage(limit: limit)
    }

    private func buildOutputShowsCompilerError(_ output: String) -> Bool {
        let markers = ["error:", "fatal error:", "BUILD FAILED", "The following build commands failed"]
        return markers.contains { marker in
            output.localizedCaseInsensitiveContains(marker)
        }
    }
}

private extension String {
    func truncatedForDoctorMessage(limit: Int = 500) -> String {
        guard count > limit else {
            return self
        }
        let endIndex = index(startIndex, offsetBy: limit)
        return "\(self[..<endIndex])..."
    }
}

extension DoctorProjectPreflight: SimulatorLifecycleTooling {
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
            environment: context.profile.env
                .merging(context.envOverrides) { _, override in override }
                .merging(environmentOverrides) { _, override in override },
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
