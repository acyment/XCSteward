import Foundation

struct DoctorCoreSimulatorHealth {
    let environment: AppEnvironment
    private let probeRunner: DoctorJSONProbeRunner
    private let xcodeEnvironment: DoctorXcodeEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        probeRunner = DoctorJSONProbeRunner(environment: environment)
        xcodeEnvironment = DoctorXcodeEnvironment(environment: environment)
    }

    func simulatorRuntimeInstalledCheck() throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.simulator_runtime_installed",
            summary: "simulator runtime availability"
        ) {
            return skipped
        }

        let runtimes: [CoreSimulatorRuntimeProbe]
        switch try probeRunner.runSimulatorRuntimesProbe() {
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

    func iPhoneSimulatorRuntimeCompatibilityCheck() throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.iphonesimulator_runtime_compatible",
            summary: "iphonesimulator SDK/runtime compatibility"
        ) {
            return skipped
        }

        let showsdks = try environment.toolRunner.run(
            tool: "xcodebuild",
            arguments: ["-showsdks"],
            environment: [:],
            workingDirectory: nil,
            timeout: 20
        )
        guard showsdks.exitCode == 0, !showsdks.timedOut else {
            return makeCheck(
                id: "global.iphonesimulator_runtime_compatible",
                status: .warn,
                message: "iphonesimulator SDK/runtime compatibility check skipped because xcodebuild -showsdks failed",
                manualAction: "Run xcodebuild -showsdks and xcrun simctl list runtimes --json manually to verify simulator SDK/runtime compatibility"
            )
        }

        let sdkVersions = DoctorOutputParsers.iPhoneSimulatorSDKVersions(fromShowsdksOutput: showsdks.output)
        guard !sdkVersions.isEmpty else {
            return makeCheck(
                id: "global.iphonesimulator_runtime_compatible",
                status: .pass,
                message: "iphonesimulator SDK/runtime compatibility check skipped because no iphonesimulator SDK version was exposed"
            )
        }

        let runtimes: [CoreSimulatorRuntimeProbe]
        switch try probeRunner.runSimulatorRuntimesProbe() {
        case .success(let parsedRuntimes):
            runtimes = parsedRuntimes
        case .failure:
            return makeCheck(
                id: "global.iphonesimulator_runtime_compatible",
                status: .warn,
                message: "Unable to compare iphonesimulator SDKs with installed Simulator runtimes",
                manualAction: "Run xcodebuild -showsdks and xcrun simctl list runtimes --json manually to verify simulator SDK/runtime compatibility"
            )
        }

        let runtimeVersions = Set(runtimes.compactMap { runtime -> String? in
            guard runtime.isIOSRuntime, runtime.isAvailable else {
                return nil
            }
            return runtime.normalizedVersion
        })
        guard !runtimeVersions.isEmpty else {
            return makeCheck(
                id: "global.iphonesimulator_runtime_compatible",
                status: .fail,
                message: "No available iOS Simulator runtime can be matched against the selected Xcode's iphonesimulator SDK",
                manualAction: "Install an iOS Simulator runtime compatible with the selected Xcode"
            )
        }

        let compatibleVersions = sdkVersions.intersection(runtimeVersions)
        guard compatibleVersions.isEmpty else {
            let versions = compatibleVersions.sorted().joined(separator: ", ")
            return makeCheck(
                id: "global.iphonesimulator_runtime_compatible",
                status: .pass,
                message: "Selected Xcode iphonesimulator SDK and installed iOS Simulator runtime are compatible: \(versions)"
            )
        }

        return makeCheck(
            id: "global.iphonesimulator_runtime_compatible",
            status: .fail,
            message: "Selected Xcode exposes iphonesimulator SDK \(sdkVersions.sorted().joined(separator: ", ")), but available iOS Simulator runtimes are \(runtimeVersions.sorted().joined(separator: ", "))",
            manualAction: "Install a matching iOS Simulator runtime for the selected Xcode, or switch xcode-select to an Xcode that matches the installed runtime"
        )
    }

    func simulatorRuntimeUnavailableCheck() throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.simulator_runtime_unavailable",
            summary: "unavailable Simulator runtimes"
        ) {
            return skipped
        }

        let runtimes: [CoreSimulatorRuntimeProbe]
        switch try probeRunner.runSimulatorRuntimesProbe() {
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

    func runtimeDyldCacheStateCheck() throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.runtime_dyld_cache_state",
            summary: "Simulator runtime dyld cache state"
        ) {
            return skipped
        }

        let runtimes: [CoreSimulatorRuntimeProbe]
        switch try probeRunner.runSimulatorRuntimesProbe() {
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

    func unavailableDevicesCleanupCheck(fixOptions: DoctorFixOptions) throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.unavailable_devices_cleanup",
            summary: "unavailable Simulator device cleanup"
        ) {
            return skipped
        }

        let deviceList: CoreSimulatorDeviceListProbe
        switch try probeRunner.runDecodableJSONProbe(
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
                autoFixable: false,
                manualAction: "Run xcrun simctl list devices --json manually and inspect CoreSimulator errors before considering danger-confirmed global cleanup"
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
            manualAction: "Run doctor --fix-global --dangerously-confirm-global-coresimulator-cleanup to execute xcrun simctl delete unavailable"
        )
    }

    func coreSimulatorListJSONHealthCheck() throws -> DoctorCheck {
        if let skipped = try skippedSimctlDependentCheck(
            id: "global.coresim_list_json_health",
            summary: "CoreSimulator JSON enumeration"
        ) {
            return skipped
        }

        switch try probeRunner.runJSONProbe(tool: "xcrun", arguments: ["simctl", "list", "--json"], timeout: 2) {
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

    private func unavailableSimulatorDevices(in probe: CoreSimulatorDeviceListProbe) -> [String] {
        probe.devices.values
            .flatMap { $0 }
            .filter(\.isUnavailable)
            .map(\.displayName)
    }

    func skippedSimctlDependentCheck(id: String, summary: String) throws -> DoctorCheck? {
        let select = try xcodeEnvironment.selectedDeveloperDirectory()
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

        let selectedDeveloperDir = normalizeDoctorPath(select.output)
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
}
