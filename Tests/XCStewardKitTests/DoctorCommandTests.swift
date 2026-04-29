import Foundation
import XCTest
@testable import XCStewardKit

final class DoctorCommandTests: XCTestCase {
    func testDoctorFailsWhenNoRunnableIOSSimulatorDestinationExists() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .noRunnableDestinations)
        try createProfile(
            name: "destinations",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "destinations", environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let destinations = try result.check("project.showdestinations_runnable")
        XCTAssertEqual(destinations["status"] as? String, "fail")
        XCTAssertTrue((destinations["message"] as? String)?.contains("iOS Simulator") == true)
    }

    func testDoctorFailsWhenConfiguredTestPlanIsMissing() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingTestPlan)
        try createProfile(
            name: "testplan",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_test_plan = "Stable"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "testplan", environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let testPlan = try result.check("project.testplan_exists")
        XCTAssertEqual(testPlan["status"] as? String, "fail")
        XCTAssertTrue((testPlan["message"] as? String)?.contains("Stable") == true)
    }

    func testDoctorWarnsWhenDerivedDataPathIsInsideTheRepo() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "deriveddata",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [env]
            DERIVED_DATA_PATH = "\(repoRoot.appendingPathComponent("DerivedData").path)"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "deriveddata", environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let derivedData = try result.check("project.derived_data_isolation")
        XCTAssertEqual(derivedData["status"] as? String, "warn")
        XCTAssertTrue((derivedData["message"] as? String)?.contains("DerivedData") == true)
    }

    func testDoctorWarnsWhenXcodeManagedParallelWorkersMayCreateCloneSimulators() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "parallel-clones",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [parallel]
            mode = "xcode-managed"
            max_workers = 4
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "parallel-clones", environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let parallelism = try result.check("project.xcode_managed_parallel_workers")
        XCTAssertEqual(parallelism["status"] as? String, "warn")
        XCTAssertTrue((parallelism["message"] as? String)?.contains("clone simulators") == true)
    }

    func testDoctorFailsWhenStateVolumeHasTooLittleFreeDiskSpace() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: [
                "XCSTEWARD_DOCTOR_MIN_FREE_BYTES": "\(Int64.max)",
                "XCSTEWARD_DOCTOR_WARN_FREE_BYTES": "\(Int64.max)",
            ]
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let disk = try result.check("global.free_disk_space")
        XCTAssertEqual(disk["status"] as? String, "fail")
        XCTAssertTrue((disk["message"] as? String)?.contains("free") == true)
    }

    func testDoctorWarnsWhenStateVolumeHasDiskPressure() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: ["XCSTEWARD_DOCTOR_WARN_FREE_PERCENT": "101"]
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let diskPressure = try result.check("global.disk_pressure_warning")
        XCTAssertEqual(diskPressure["status"] as? String, "warn")
        XCTAssertTrue((diskPressure["message"] as? String)?.contains("Disk pressure") == true)
    }

    func testDoctorWarnsWhenStateRootIsUnderProtectedPath() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: ["XCSTEWARD_DOCTOR_PROTECTED_PATHS": stateRoot.path]
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let protectedPath = try result.check("global.protected_path_warning")
        XCTAssertEqual(protectedPath["status"] as? String, "warn")
        XCTAssertTrue((protectedPath["message"] as? String)?.contains("protected") == true)
    }

    func testDoctorFailsWhenConfiguredBootedSimulatorDoesNotRespondToBootstatus() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .bootedSimulatorNeedsRecovery)
        try createProfile(
            name: "booted-sim",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "booted-sim", environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let bootstatus = try result.check("project.default_simulator_bootstatus")
        XCTAssertEqual(bootstatus["status"] as? String, "fail")
        XCTAssertTrue((bootstatus["message"] as? String)?.contains("bootstatus") == true)
    }

    func testDoctorFailsWhenPackageResolutionPreflightFails() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .packageResolutionFailure)
        try createProfile(
            name: "packages",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "packages", environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let packages = try result.check("project.package_resolution_preflight")
        XCTAssertEqual(packages["status"] as? String, "fail")
        XCTAssertTrue((packages["message"] as? String)?.contains("Package") == true)
    }

    func testDoctorFailsWhenBuildForTestingDoesNotProduceXCTestRun() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingXCTestRun)
        try createProfile(
            name: "xctestrun",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "xctestrun", environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let integrity = try result.check("project.xctestrun_integrity")
        XCTAssertEqual(integrity["status"] as? String, "fail")
        XCTAssertTrue((integrity["message"] as? String)?.contains(".xctestrun") == true)
    }

    func testDoctorFailsWhenModernXCResultToolParserIsUnavailable() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .legacyXCResultTool)
        try createProfile(
            name: "xcresulttool",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "xcresulttool", environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let xcresulttool = try result.check("project.xcresulttool_compat")
        XCTAssertEqual(xcresulttool["status"] as? String, "fail")
        XCTAssertTrue((xcresulttool["message"] as? String)?.contains("xcresulttool") == true)
    }

    func testDoctorPassesWhenModernXCResultToolHelpIsAvailableViaSubcommand() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "xcresulttool-modern",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "xcresulttool-modern", environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        let xcresulttool = try result.check("project.xcresulttool_compat")
        XCTAssertEqual(xcresulttool["status"] as? String, "pass")
    }

    func testDoctorUsesConfiguredProjectWhenCheckingSchemeAvailability() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .projectScopedListRequired)
        try createProfile(
            name: "project-scoped-scheme",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "project-scoped-scheme", environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        let scheme = try result.check("project.scheme")
        XCTAssertEqual(scheme["status"] as? String, "pass")
    }

    func testDoctorIgnoresXcodeBuildMCPProcessWhenCheckingRunnerContention() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .xcodebuildMCPProcess)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        let contention = try result.check("global.concurrent_runner_contention")
        XCTAssertEqual(contention["status"] as? String, "pass")
    }

    func testDoctorIgnoresIdleSimulatorAppWhenCheckingRunnerContention() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .simulatorAppProcess)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        let contention = try result.check("global.concurrent_runner_contention")
        XCTAssertEqual(contention["status"] as? String, "pass")
    }

    func testDoctorFailsWhenStaleSimulatorLeaseExists() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertTrue(try store.acquireSimulatorLease(simulatorID: "SIM-STALE", jobID: "dead-job", pid: 0))

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let leases = try result.check("global.simulator_leases")
        XCTAssertEqual(leases["status"] as? String, "fail")
        XCTAssertEqual(leases["auto_fixable"] as? Bool, true)
        XCTAssertTrue((leases["message"] as? String)?.contains("SIM-STALE") == true)
    }

    func testDoctorFixRecoversStaleSimulatorLeases() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        let store = try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
        XCTAssertTrue(try store.acquireSimulatorLease(simulatorID: "SIM-STALE", jobID: "dead-job", pid: 0))

        let result = try runDoctorCommand(stateRoot: stateRoot, fix: true, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "pass")
        let leases = try result.check("global.simulator_leases")
        XCTAssertEqual(leases["status"] as? String, "pass")
        XCTAssertEqual(leases["fixed"] as? Bool, true)
        XCTAssertTrue((leases["message"] as? String)?.contains("Recovered 1 stale simulator lease") == true)
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }

    func testDoctorFailsWhenNoAvailableSimulatorRuntimeIsInstalled() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .noAvailableSimulatorRuntime)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let runtime = try result.check("global.simulator_runtime_installed")
        XCTAssertEqual(runtime["status"] as? String, "fail")
        XCTAssertTrue((runtime["message"] as? String)?.contains("runtime") == true)
    }

    func testDoctorWarnsWhenInstalledSimulatorRuntimeIsUnavailable() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .unavailableSimulatorRuntime)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let runtime = try result.check("global.simulator_runtime_unavailable")
        XCTAssertEqual(runtime["status"] as? String, "warn")
        XCTAssertTrue((runtime["message"] as? String)?.contains("unavailable") == true)
    }

    func testDoctorFailsWhenSimulatorRuntimeReportsDyldCacheError() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .runtimeDyldCacheUnavailable)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let dyld = try result.check("global.runtime_dyld_cache_state")
        XCTAssertEqual(dyld["status"] as? String, "fail")
        XCTAssertTrue((dyld["message"] as? String)?.contains("dyld") == true)
    }

    func testDoctorWarnsWhenUnavailableSimulatorDevicesExist() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .unavailableSimulatorDevice)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let devices = try result.check("global.unavailable_devices_cleanup")
        XCTAssertEqual(devices["status"] as? String, "warn")
        XCTAssertEqual(devices["auto_fixable"] as? Bool, true)
        XCTAssertTrue((devices["message"] as? String)?.contains("Old iPhone") == true)
    }

    func testDoctorFixDeletesUnavailableSimulatorDevices() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .unavailableSimulatorDevice)

        let result = try runDoctorCommand(stateRoot: stateRoot, fix: true, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "pass")
        let devices = try result.check("global.unavailable_devices_cleanup")
        XCTAssertEqual(devices["status"] as? String, "pass")
        XCTAssertEqual(devices["fixed"] as? Bool, true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(log.contains("xcrun simctl delete unavailable"))
    }

    func testDoctorFailsWhenCoreSimulatorJsonEnumerationHangs() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .hungCoreSimulatorList)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let coreSim = try result.check("global.coresim_list_json_health")
        XCTAssertEqual(coreSim["status"] as? String, "fail")
        XCTAssertTrue((coreSim["message"] as? String)?.contains("simctl list --json") == true)
    }

    func testDoctorWarnsWhenCompetingLocalRunnerProcessesAreDetected() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .concurrentRunnerContention)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let contention = try result.check("global.concurrent_runner_contention")
        XCTAssertEqual(contention["status"] as? String, "warn")
        XCTAssertTrue((contention["message"] as? String)?.contains("Competing") == true)
    }

    func testDoctorWarnsWhenProcessListingProbeCannotRun() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingProcessLister)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let contention = try result.check("global.concurrent_runner_contention")
        XCTAssertEqual(contention["status"] as? String, "warn")
        XCTAssertTrue((contention["message"] as? String)?.contains("Unable to determine") == true)
    }

    func testDoctorFailsWhenSelectedDeveloperDirIsCommandLineTools() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .commandLineToolsSelection)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let selection = try result.check("global.clt_vs_xcode_selection")
        XCTAssertEqual(selection["status"] as? String, "fail")
        XCTAssertTrue((selection["message"] as? String)?.contains("Command Line Tools") == true)
    }

    func testDoctorWarnsWhenDeveloperDirEnvironmentOverridesSelectedXcode() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: ["DEVELOPER_DIR": "/Applications/AltXcode.app/Contents/Developer"]
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let override = try result.check("global.developer_dir_env_override")
        XCTAssertEqual(override["status"] as? String, "warn")
        XCTAssertTrue((override["message"] as? String)?.contains("DEVELOPER_DIR") == true)
    }

    func testDoctorFailsWhenFirstLaunchComponentsAreMissing() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingFirstLaunchComponents)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let components = try result.check("global.first_launch_components")
        XCTAssertEqual(components["status"] as? String, "fail")
        XCTAssertTrue((components["message"] as? String)?.contains("first-launch") == true)
    }

    func testDoctorFailsWhenIPhoneSimulatorSDKIsMissing() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingIPhoneSimulatorSDK)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let sdk = try result.check("global.iphonesimulator_sdk_present")
        XCTAssertEqual(sdk["status"] as? String, "fail")
        XCTAssertTrue((sdk["message"] as? String)?.contains("iphonesimulator") == true)
    }

    func testDoctorFallsBackToPlatformBundleWhenShowSDKsFails() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .showsdksFailureWithSDKOnDisk)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "pass")
        let sdk = try result.check("global.iphonesimulator_sdk_present")
        XCTAssertEqual(sdk["status"] as? String, "pass")
        XCTAssertTrue((sdk["message"] as? String)?.contains("xcodebuild -showsdks failed") == true)
    }

    func testDoctorFailsWhenSelectedXcodeAndCLICommandVersionsDiffer() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .xcodeVersionMismatch)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let alignment = try result.check("global.xcode_cli_alignment")
        XCTAssertEqual(alignment["status"] as? String, "fail")
        XCTAssertTrue((alignment["message"] as? String)?.contains("does not match") == true)
    }

    func testDoctorReportsMissingManagedSimulatorWithoutFix() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .listSchemes)
        try createProfile(
            name: "managed",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Managed Device"
            device_type = "iPhone 17 Pro"
            runtime = "iOS 26.4"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "managed", environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let managed = try result.check("project.managed_simulator")
        XCTAssertEqual(managed["auto_fixable"] as? Bool, true)
    }

    func testDoctorFixCreatesManagedSimulatorAndRecoversStaleLease() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .listSchemes)
        try createProfile(
            name: "managed",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "Managed Device"
            device_type = "iPhone 17 Pro"
            runtime = "iOS 26.4"
            """
        )
        try seedStaleLease(stateRoot: stateRoot)

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "managed", fix: true, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "pass")
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(log.contains("xcrun simctl create Managed Device"))
        XCTAssertFalse(log.contains("shutdown all"))
    }
}

private struct DoctorCommandResult {
    var cli: CLIResult
    var json: [String: Any]

    var overallStatus: String? {
        json["overall_status"] as? String
    }

    func check(
        _ id: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]], file: file, line: line)
        return try XCTUnwrap(
            checks.first(where: { ($0["id"] as? String) == id }),
            "Missing doctor check \(id)",
            file: file,
            line: line
        )
    }
}

private func runDoctorCommand(
    stateRoot: URL,
    project: String? = nil,
    fix: Bool = false,
    environment: [String: String],
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> DoctorCommandResult {
    var arguments = [
        "doctor",
        "--state-root", stateRoot.path,
    ]
    if let project {
        arguments.append(contentsOf: ["--project", project])
    }
    if fix {
        arguments.append("--fix")
    }
    arguments.append("--json")

    let cli = try runCLI(arguments: arguments, environment: environment)
    let json = try XCTUnwrap(parseJSON(cli.stdout) as? [String: Any], file: file, line: line)
    return DoctorCommandResult(cli: cli, json: json)
}
