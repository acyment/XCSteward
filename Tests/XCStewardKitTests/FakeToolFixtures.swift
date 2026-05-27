// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

enum FakeScenario: String {
    case success
    case manualShards = "manual_shards"
    case manualShardMergeFailure = "manual_shard_merge_failure"
    case manualShardBootstrapRetry = "manual_shard_bootstrap_retry"
    case manualShardBootstrapRetryWithPartialResult = "manual_shard_bootstrap_retry_with_partial_result"
    case manualShardFatalShortCircuit = "manual_shard_fatal_short_circuit"
    case manualShardsConcurrent = "manual_shards_concurrent"
    case buildFailure = "build_failure"
    case buildTimeout = "build_timeout"
    case bootstrapRetry = "bootstrap_retry"
    case bootstrapRetryWithPartialResult = "bootstrap_retry_with_partial_result"
    case bootStatusFailure = "boot_status_failure"
    case bootedSimulatorNeedsRecovery = "booted_simulator_needs_recovery"
    case simulatorBootCancellation = "simulator_boot_cancellation"
    case simulatorDisappearsDuringBoot = "simulator_disappears_during_boot"
    case slowSuccess = "slow_success"
    case queuedCancellation = "queued_cancellation"
    case parallelMixedOutcomes = "parallel_mixed_outcomes"
    case parallelCancellation = "parallel_cancellation"
    case dynamicBackpressure = "dynamic_backpressure"
    case managedSimulatorStatusLine = "managed_simulator_status_line"
    case projectScopedListRequired = "project_scoped_list_required"
    case xcodebuildListJSONWithWarningPrefix = "xcodebuild_list_json_with_warning_prefix"
    case xctestrunRejectsTestPlan = "xctestrun_rejects_testplan"
    case generatedXCTESTRunPath = "generated_xctestrun_path"
    case runnerConfigurationFailureWithXCResult = "runner_configuration_failure_with_xcresult"
    case runningCancellation = "running_cancellation"
    case testCancellation = "test_cancellation"
    case postTestArtifactCancellation = "post_test_artifact_cancellation"
    case workerCrashDuringBuild = "worker_crash_during_build"
    case workerCrashDuringTest = "worker_crash_during_test"
    case managedSimulatorCreateRequiresIdentifiers = "managed_simulator_create_requires_identifiers"
    case managedSimulatorCreateFailure = "managed_simulator_create_failure"
    case managedSimulatorCreateNoisySuccess = "managed_simulator_create_noisy_success"
    case managedSimulatorListHangs = "managed_simulator_list_hangs"
    case junitGenerationFailure = "junit_generation_failure"
    case missingXCResultSuccess = "missing_xcresult_success"
    case corruptXCResultSuccess = "corrupt_xcresult_success"
    case xcresultSummaryTimeoutSuccess = "xcresult_summary_timeout_success"
    case modernXCResultToolSummary = "modern_xcresulttool_summary"
    case testTimeout = "test_timeout"
    case listSchemes = "list_schemes"
    case xcodebuildListFailure = "xcodebuild_list_failure"
    case xcodeVersionMismatch = "xcode_version_mismatch"
    case commandLineToolsSelection = "command_line_tools_selection"
    case missingFirstLaunchComponents = "missing_first_launch_components"
    case xcodebuildUnavailable = "xcodebuild_unavailable"
    case missingIPhoneSimulatorSDK = "missing_iphonesimulator_sdk"
    case showsdksWarningOnly = "showsdks_warning_only"
    case showsdksFailureWithSDKOnDisk = "showsdks_failure_with_sdk_on_disk"
    case iPhoneSimulatorSDKRuntimeMismatch = "iphonesimulator_sdk_runtime_mismatch"
    case noAvailableSimulatorRuntime = "no_available_simulator_runtime"
    case textualSimulatorRuntimeAvailability = "textual_simulator_runtime_availability"
    case negativeTextSimulatorRuntimeAvailability = "negative_text_simulator_runtime_availability"
    case flagSimulatorRuntimeAvailability = "flag_simulator_runtime_availability"
    case unavailableSimulatorRuntime = "unavailable_simulator_runtime"
    case runtimeDyldCacheUnavailable = "runtime_dyld_cache_unavailable"
    case unavailableSimulatorDevice = "unavailable_simulator_device"
    case coreSimulatorDeviceListFailure = "coresimulator_device_list_failure"
    case textualUnavailableSimulatorDevice = "textual_unavailable_simulator_device"
    case flagUnavailableSimulatorDevice = "flag_unavailable_simulator_device"
    case hungCoreSimulatorList = "hung_coresimulator_list"
    case concurrentRunnerContention = "concurrent_runner_contention"
    case missingProcessLister = "missing_process_lister"
    case macOSOnlyDestination = "macos_only_destination"
    case noRunnableDestinations = "no_runnable_destinations"
    case placeholderIOSSimulatorDestination = "placeholder_ios_simulator_destination"
    case transientPlaceholderIOSSimulatorDestination = "transient_placeholder_ios_simulator_destination"
    case spacedIOSSimulatorDestination = "spaced_ios_simulator_destination"
    case missingTestPlan = "missing_test_plan"
    case packageResolutionFailure = "package_resolution_failure"
    case missingXCTestRun = "missing_xctestrun"
    case staleDoctorXCTestRun = "stale_doctor_xctestrun"
    case legacyXCResultTool = "legacy_xcresulttool"
    case xcodebuildMCPProcess = "xcodebuildmcp_process"
    case simulatorAppProcess = "simulator_app_process"
    case memoryPressureWarning = "memory_pressure_warning"
    case thermalStateSerious = "thermal_state_serious"
}

struct FakeToolEnvironment {
    let root: URL
    let bin: URL
    let log: URL
    let env: [String: String]
}

func makeFakeToolEnvironment(scenario: FakeScenario, extraEnv: [String: String] = [:]) throws -> FakeToolEnvironment {
    let root = try makeTempDirectory(function: "FakeToolEnvironment")
    let bin = root.appendingPathComponent("bin")
    let log = root.appendingPathComponent("tool.log")
    let xcodeContents = root.appendingPathComponent("FakeXcode.app/Contents")
    let xcodeDeveloper = xcodeContents.appendingPathComponent("Developer")
    let xcodebuildPath = xcodeDeveloper.appendingPathComponent("usr/bin/xcodebuild")
    let selectedDeveloperPath: String = scenario == .commandLineToolsSelection
        ? "/Library/Developer/CommandLineTools"
        : xcodeDeveloper.path
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: xcodebuildPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    if scenario == .showsdksFailureWithSDKOnDisk {
        try FileManager.default.createDirectory(
            at: xcodeDeveloper.appendingPathComponent("Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator18.0.sdk"),
            withIntermediateDirectories: true
        )
    }
    try writeText(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key>
            <string>16.4</string>
            <key>ProductBuildVersion</key>
            <string>16F6</string>
        </dict>
        </plist>
        """,
        to: xcodeContents.appendingPathComponent("version.plist")
    )

    let commonEnv: [String: String] = [
        "FAKE_TOOL_ROOT": root.path,
        "FAKE_TOOL_LOG": log.path,
        "FAKE_TOOL_SCENARIO": scenario.rawValue,
        "FAKE_XCODE_SELECT_PATH": selectedDeveloperPath,
        "FAKE_XCODEBUILD_PATH": xcodebuildPath.path,
        "XCSTEWARD_DOCTOR_MIN_FREE_BYTES": "0",
        "XCSTEWARD_DOCTOR_WARN_FREE_BYTES": "0",
        "XCSTEWARD_DOCTOR_WARN_FREE_PERCENT": "0",
    ].merging(extraEnv, uniquingKeysWith: { _, new in new })

    try FakeToolScripts.installAll(into: bin)

    let env = [
        "PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
    ].merging(commonEnv, uniquingKeysWith: { _, new in new })

    return FakeToolEnvironment(root: root, bin: bin, log: log, env: env)
}

struct FakeToolScript {
    let name: String
    let contents: String
}

enum FakeToolScripts {
    static func installAll(into bin: URL) throws {
        for script in all {
            try writeExecutable(script.contents, to: bin.appendingPathComponent(script.name))
        }
    }

    private static var all: [FakeToolScript] {
        [xcodebuild, xcrun] + utilityScripts
    }
}
