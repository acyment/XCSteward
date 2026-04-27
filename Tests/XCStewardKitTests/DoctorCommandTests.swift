import Foundation
import XCTest

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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "destinations",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let destinations: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "project.showdestinations_runnable" }))
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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "testplan",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let testPlan: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "project.testplan_exists" }))
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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "deriveddata",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "warn")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let derivedData: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "project.derived_data_isolation" }))
        XCTAssertEqual(derivedData["status"] as? String, "warn")
        XCTAssertTrue((derivedData["message"] as? String)?.contains("DerivedData") == true)
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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "booted-sim",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let bootstatus: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "project.default_simulator_bootstatus" }))
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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "packages",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let packages: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "project.package_resolution_preflight" }))
        XCTAssertEqual(packages["status"] as? String, "fail")
        XCTAssertTrue((packages["message"] as? String)?.contains("Package") == true)
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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "xcresulttool",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let xcresulttool: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "project.xcresulttool_compat" }))
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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "xcresulttool-modern",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let xcresulttool: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "project.xcresulttool_compat" }))
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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "project-scoped-scheme",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let scheme: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "project.scheme" }))
        XCTAssertEqual(scheme["status"] as? String, "pass")
    }

    func testDoctorIgnoresXcodeBuildMCPProcessWhenCheckingRunnerContention() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .xcodebuildMCPProcess)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let contention = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.concurrent_runner_contention" }))
        XCTAssertEqual(contention["status"] as? String, "pass")
    }

    func testDoctorIgnoresIdleSimulatorAppWhenCheckingRunnerContention() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .simulatorAppProcess)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let contention = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.concurrent_runner_contention" }))
        XCTAssertEqual(contention["status"] as? String, "pass")
    }

    func testDoctorFailsWhenNoAvailableSimulatorRuntimeIsInstalled() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .noAvailableSimulatorRuntime)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let runtime: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.simulator_runtime_installed" }))
        XCTAssertEqual(runtime["status"] as? String, "fail")
        XCTAssertTrue((runtime["message"] as? String)?.contains("runtime") == true)
    }

    func testDoctorWarnsWhenInstalledSimulatorRuntimeIsUnavailable() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .unavailableSimulatorRuntime)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "warn")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let runtime: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.simulator_runtime_unavailable" }))
        XCTAssertEqual(runtime["status"] as? String, "warn")
        XCTAssertTrue((runtime["message"] as? String)?.contains("unavailable") == true)
    }

    func testDoctorFailsWhenCoreSimulatorJsonEnumerationHangs() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .hungCoreSimulatorList)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let coreSim: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.coresim_list_json_health" }))
        XCTAssertEqual(coreSim["status"] as? String, "fail")
        XCTAssertTrue((coreSim["message"] as? String)?.contains("simctl list --json") == true)
    }

    func testDoctorWarnsWhenCompetingLocalRunnerProcessesAreDetected() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .concurrentRunnerContention)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "warn")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let contention: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.concurrent_runner_contention" }))
        XCTAssertEqual(contention["status"] as? String, "warn")
        XCTAssertTrue((contention["message"] as? String)?.contains("Competing") == true)
    }

    func testDoctorWarnsWhenProcessListingProbeCannotRun() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingProcessLister)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "warn")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let contention: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.concurrent_runner_contention" }))
        XCTAssertEqual(contention["status"] as? String, "warn")
        XCTAssertTrue((contention["message"] as? String)?.contains("Unable to determine") == true)
    }

    func testDoctorFailsWhenSelectedDeveloperDirIsCommandLineTools() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .commandLineToolsSelection)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let selection: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.clt_vs_xcode_selection" }))
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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "warn")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let override = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.developer_dir_env_override" }))
        XCTAssertEqual(override["status"] as? String, "warn")
        XCTAssertTrue((override["message"] as? String)?.contains("DEVELOPER_DIR") == true)
    }

    func testDoctorFailsWhenFirstLaunchComponentsAreMissing() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingFirstLaunchComponents)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let components: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.first_launch_components" }))
        XCTAssertEqual(components["status"] as? String, "fail")
        XCTAssertTrue((components["message"] as? String)?.contains("first-launch") == true)
    }

    func testDoctorFailsWhenIPhoneSimulatorSDKIsMissing() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingIPhoneSimulatorSDK)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let sdk: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.iphonesimulator_sdk_present" }))
        XCTAssertEqual(sdk["status"] as? String, "fail")
        XCTAssertTrue((sdk["message"] as? String)?.contains("iphonesimulator") == true)
    }

    func testDoctorFallsBackToPlatformBundleWhenShowSDKsFails() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .showsdksFailureWithSDKOnDisk)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "pass")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let sdk: [String: Any] = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.iphonesimulator_sdk_present" }))
        XCTAssertEqual(sdk["status"] as? String, "pass")
        XCTAssertTrue((sdk["message"] as? String)?.contains("xcodebuild -showsdks failed") == true)
    }

    func testDoctorFailsWhenSelectedXcodeAndCLICommandVersionsDiffer() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .xcodeVersionMismatch)

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        let alignment = try XCTUnwrap(checks.first(where: { ($0["id"] as? String) == "global.xcode_cli_alignment" }))
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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "managed",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertNotEqual(result.status, 0)
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "fail")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        XCTAssertTrue(checks.contains { ($0["id"] as? String) == "project.managed_simulator" && ($0["auto_fixable"] as? Bool) == true })
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

        let result = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "managed",
                "--fix",
                "--json",
            ],
            environment: fakeTools.env
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["overall_status"] as? String, "pass")
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(log.contains("xcrun simctl create Managed Device"))
        XCTAssertFalse(log.contains("shutdown all"))
    }
}
