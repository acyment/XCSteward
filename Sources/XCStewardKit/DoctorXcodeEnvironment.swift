import Foundation

struct DoctorXcodeEnvironment {
    let environment: AppEnvironment

    func developerDirEnvironmentOverrideCheck() throws -> DoctorCheck {
        guard let override = environment.processInfo.environment["DEVELOPER_DIR"],
              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return DoctorCheck(
                id: "global.developer_dir_env_override",
                status: .pass,
                message: "DEVELOPER_DIR is not overriding the selected developer directory",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        let select = try selectedDeveloperDirectory()
        guard select.exitCode == 0 else {
            return DoctorCheck(
                id: "global.developer_dir_env_override",
                status: .warn,
                message: "DEVELOPER_DIR is set, but xcode-select -p could not be read for comparison",
                autoFixable: false,
                fixed: false,
                manualAction: "Unset DEVELOPER_DIR or align it with the intended Xcode.app developer directory"
            )
        }

        let normalizedOverride = normalizeDoctorPath(override)
        let selectedDeveloperDir = normalizeDoctorPath(select.output)
        if normalizedOverride == selectedDeveloperDir {
            return DoctorCheck(
                id: "global.developer_dir_env_override",
                status: .pass,
                message: "DEVELOPER_DIR matches the selected developer directory",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }

        return DoctorCheck(
            id: "global.developer_dir_env_override",
            status: .warn,
            message: "DEVELOPER_DIR overrides xcode-select -p with a different developer directory",
            autoFixable: false,
            fixed: false,
            manualAction: "Unset DEVELOPER_DIR or align it with the selected Xcode.app developer directory"
        )
    }

    func commandLineToolsSelectionCheck() throws -> DoctorCheck {
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

        let selectedDeveloperDir = normalizeDoctorPath(select.output)
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

    func firstLaunchComponentsCheck() throws -> DoctorCheck {
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

        let selectedDeveloperDir = normalizeDoctorPath(select.output)
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

    func iPhoneSimulatorSDKPresenceCheck() throws -> DoctorCheck {
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

        let selectedDeveloperDir = normalizeDoctorPath(select.output)
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

    func xcodeCLIAlignmentCheck() throws -> DoctorCheck {
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

        let selectedDeveloperDir = normalizeDoctorPath(select.output)
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

        let xcodebuildPath = normalizeDoctorPath(found.output)
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

    func selectedDeveloperDirectory() throws -> ToolResult {
        try environment.toolRunner.run(
            tool: "xcode-select",
            arguments: ["-p"],
            environment: [:],
            workingDirectory: nil,
            timeout: 10
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

    private func parseXcodeVersion(from output: String) -> String? {
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("Xcode ") {
                return String(text.dropFirst("Xcode ".count))
            }
        }
        return nil
    }
}
