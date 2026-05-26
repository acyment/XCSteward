import Foundation
import XCTest

final class DoctorProjectPreflightCommandTests: XCTestCase {
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
        XCTAssertEqual(destinations["auto_fixable"] as? Bool, false)
        XCTAssertEqual(destinations["fixed"] as? Bool, false)
        XCTAssertTrue((destinations["message"] as? String)?.contains("iOS Simulator") == true)
        let manualAction = destinations["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Adjust the scheme or destination settings") == true)
    }

    func testDoctorRejectsPlaceholderIOSSimulatorDestinationAndSkipsXCTestRunIntegrityBuild() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .placeholderIOSSimulatorDestination)
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
        XCTAssertTrue((destinations["message"] as? String)?.contains("placeholder") == true)
        let manualAction = destinations["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("xcrun simctl list devices --json") == true)
        let xctestrun = try result.check("project.xctestrun_integrity")
        XCTAssertEqual(xctestrun["status"] as? String, "pass")
        XCTAssertTrue((xctestrun["message"] as? String)?.contains("skipped") == true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertFalse(log.contains("build-for-testing"))
    }

    func testDoctorRetriesTransientPlaceholderIOSSimulatorDestination() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .transientPlaceholderIOSSimulatorDestination)
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

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        let destinations = try result.check("project.showdestinations_runnable")
        XCTAssertEqual(destinations["status"] as? String, "pass")
        XCTAssertTrue((destinations["message"] as? String)?.contains("after retrying transient placeholder-only output") == true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertEqual(log.components(separatedBy: "-showdestinations").count - 1, 2)
        XCTAssertTrue(log.contains("build-for-testing"))
    }

    func testDoctorUsesConcreteSimulatorDestinationForXCTestRunIntegrityBuild() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "xctestrun-destination",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "xctestrun-destination", environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(log.contains("-destination id=SIM-123"), log)
        XCTAssertFalse(log.contains("-destination generic/platform=iOS Simulator"), log)
    }

    func testDoctorWarnsWhenXCTestRunIntegrityBuildTimesOut() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .buildTimeout)
        try createProfile(
            name: "xctestrun-timeout",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"

            [timeouts]
            build = 1
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "xctestrun-timeout", environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let xctestrun = try result.check("project.xctestrun_integrity")
        XCTAssertEqual(xctestrun["status"] as? String, "warn")
        XCTAssertEqual(xctestrun["auto_fixable"] as? Bool, false)
        XCTAssertEqual(xctestrun["fixed"] as? Bool, false)
        XCTAssertTrue((xctestrun["message"] as? String)?.contains("timed out") == true)
        XCTAssertTrue((xctestrun["message"] as? String)?.contains("1s") == true)
        let manualAction = xctestrun["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("full preflight assurance") == true)
        XCTAssertTrue(manualAction?.contains("submit") == true)
        let evidencePath = try XCTUnwrap(xctestrun["evidence_path"] as? String)
        XCTAssertTrue(evidencePath.hasSuffix("-build-for-testing.log"), evidencePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: evidencePath))
        XCTAssertTrue((xctestrun["failure_excerpt"] as? String)?.contains("Build started") == true)
        let evidence = try String(contentsOfFile: evidencePath)
        XCTAssertTrue(evidence.contains("timed_out: true"))
        XCTAssertTrue(evidence.contains("timeout_seconds: 1s"))
        let scratchProfileRoot = stateRoot
            .appendingPathComponent("doctor/xctestrun-integrity/xctestrun-timeout")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: scratchProfileRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(leftovers.map(\.lastPathComponent), [URL(fileURLWithPath: evidencePath).lastPathComponent])
    }

    func testDoctorRetainsBuildForTestingEvidenceWhenXCTestRunIntegrityBuildFails() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .buildFailure)
        try createProfile(
            name: "xctestrun-build-failure",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "xctestrun-build-failure", environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let xctestrun = try result.check("project.xctestrun_integrity")
        XCTAssertEqual(xctestrun["status"] as? String, "fail")
        XCTAssertEqual(xctestrun["auto_fixable"] as? Bool, false)
        XCTAssertEqual(xctestrun["fixed"] as? Bool, false)
        XCTAssertTrue((xctestrun["message"] as? String)?.contains("retained evidence") == true)
        XCTAssertTrue((xctestrun["manual_action"] as? String)?.contains("retained build-for-testing evidence") == true)
        XCTAssertTrue((xctestrun["failure_excerpt"] as? String)?.contains("Build failed") == true)

        let evidencePath = try XCTUnwrap(xctestrun["evidence_path"] as? String)
        XCTAssertTrue(evidencePath.hasSuffix("-build-for-testing.log"), evidencePath)
        let evidence = try String(contentsOfFile: evidencePath)
        XCTAssertTrue(evidence.contains("command: xcodebuild"))
        XCTAssertTrue(evidence.contains("build-for-testing"))
        XCTAssertTrue(evidence.contains("exit_code: 65"))
        XCTAssertTrue(evidence.contains("timed_out: false"))
        XCTAssertTrue(evidence.contains("Build failed"))

        let scratchProfileRoot = stateRoot
            .appendingPathComponent("doctor/xctestrun-integrity/xctestrun-build-failure")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: scratchProfileRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(leftovers.map(\.lastPathComponent), [URL(fileURLWithPath: evidencePath).lastPathComponent])

        let human = try runCLI(
            arguments: [
                "doctor",
                "--state-root", stateRoot.path,
                "--project", "xctestrun-build-failure",
            ],
            environment: fakeTools.env
        )
        XCTAssertNotEqual(human.status, 0)
        XCTAssertTrue(human.stdout.contains("evidence:"))
        XCTAssertTrue(human.stdout.contains("-build-for-testing.log"))
        XCTAssertTrue(human.stdout.contains("detail: Build failed"))
    }

    func testDoctorParsesSpacedIOSSimulatorDestinationFields() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .spacedIOSSimulatorDestination)
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

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        let destinations = try result.check("project.showdestinations_runnable")
        XCTAssertEqual(destinations["status"] as? String, "pass")
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
        XCTAssertEqual(testPlan["auto_fixable"] as? Bool, false)
        XCTAssertEqual(testPlan["fixed"] as? Bool, false)
        XCTAssertTrue((testPlan["message"] as? String)?.contains("Stable") == true)
        let manualAction = testPlan["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Update the profile") == true)
        XCTAssertTrue(manualAction?.contains("Stable") == true)
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

    func testDoctorWarnsForSharedDerivedDataOverrides() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        let cases = [
            (
                name: "repo-deriveddata",
                path: repoRoot.appendingPathComponent("DerivedData").path,
                message: "inside the repository",
                manualAction: "Remove the explicit DerivedData override"
            ),
            (
                name: "shared-deriveddata",
                path: temp.appendingPathComponent("SharedDerivedData").path,
                message: "outside XCSteward job state",
                manualAction: "Prefer XCSteward-managed per-job DerivedData paths"
            ),
        ]

        for testCase in cases {
            try createProfile(
                name: testCase.name,
                stateRoot: stateRoot,
                repoRoot: repoRoot,
                body: """
                project_path = "App.xcodeproj"
                scheme = "Demo"
                [env]
                DERIVED_DATA_PATH = "\(testCase.path)"
                """
            )

            let result = try runDoctorCommand(stateRoot: stateRoot, project: testCase.name, environment: fakeTools.env)

            XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
            XCTAssertEqual(result.overallStatus, "warn")
            let derivedData = try result.check("project.derived_data_isolation")
            XCTAssertEqual(derivedData["status"] as? String, "warn")
            XCTAssertEqual(derivedData["auto_fixable"] as? Bool, false)
            XCTAssertEqual(derivedData["fixed"] as? Bool, false)
            XCTAssertTrue((derivedData["message"] as? String)?.contains(testCase.message) == true)
            XCTAssertTrue((derivedData["manual_action"] as? String)?.contains(testCase.manualAction) == true)
        }
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
        XCTAssertEqual(parallelism["auto_fixable"] as? Bool, false)
        XCTAssertEqual(parallelism["fixed"] as? Bool, false)
        XCTAssertTrue((parallelism["message"] as? String)?.contains("clone simulators") == true)
        let manualAction = parallelism["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("max_workers = 1") == true)
        XCTAssertTrue(manualAction?.contains("mode = \"serial\"") == true)
        XCTAssertTrue(manualAction?.contains("live smoke job") == true)
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
        XCTAssertEqual(packages["auto_fixable"] as? Bool, false)
        XCTAssertEqual(packages["fixed"] as? Bool, false)
        XCTAssertTrue((packages["message"] as? String)?.contains("Package") == true)
        let manualAction = packages["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("xcodebuild -resolvePackageDependencies") == true)
        XCTAssertTrue(manualAction?.contains("package issues") == true)
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

    func testDoctorRejectsStaleXCTestRunFromIntegrityScratch() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .staleDoctorXCTestRun)
        try createProfile(
            name: "stale-xctestrun",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "stale-xctestrun", environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let integrity = try result.check("project.xctestrun_integrity")
        XCTAssertEqual(integrity["status"] as? String, "fail")
        XCTAssertEqual(integrity["auto_fixable"] as? Bool, false)
        XCTAssertEqual(integrity["fixed"] as? Bool, false)
        XCTAssertTrue((integrity["message"] as? String)?.contains("current-build .xctestrun") == true)
        let manualAction = integrity["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("scheme has test targets enabled") == true)
        let scratchProfileRoot = stateRoot
            .appendingPathComponent("doctor/xctestrun-integrity/stale-xctestrun")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: scratchProfileRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Unexpected doctor scratch leftovers: \(leftovers.map(\.path))")
    }

    func testDoctorCleansXCTestRunIntegrityScratchDirectory() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .success)
        try createProfile(
            name: "clean-xctestrun",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "clean-xctestrun", environment: fakeTools.env)

        let integrity = try result.check("project.xctestrun_integrity")
        XCTAssertEqual(integrity["status"] as? String, "pass")
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(log.contains("COMPILER_INDEX_STORE_ENABLE=NO"))
        let scratchProfileRoot = stateRoot
            .appendingPathComponent("doctor/xctestrun-integrity/clean-xctestrun")
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: scratchProfileRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Unexpected doctor scratch leftovers: \(leftovers.map(\.path))")
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
        XCTAssertEqual(xcresulttool["auto_fixable"] as? Bool, false)
        XCTAssertEqual(xcresulttool["fixed"] as? Bool, false)
        XCTAssertTrue((xcresulttool["message"] as? String)?.contains("xcresulttool") == true)
        let manualAction = xcresulttool["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Xcode version") == true)
        XCTAssertTrue(manualAction?.contains("get test-results summary") == true)
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

    func testDoctorParsesSchemeListJSONWhenXcodebuildPrefixesWarnings() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .xcodebuildListJSONWithWarningPrefix)
        try createProfile(
            name: "warning-prefixed-json",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Feliche"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "warning-prefixed-json", environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        let scheme = try result.check("project.scheme")
        XCTAssertEqual(scheme["status"] as? String, "pass")
        XCTAssertFalse((scheme["message"] as? String)?.contains("Scheme is missing") == true)
    }

    func testDoctorWarnsInsteadOfReportingMissingSchemeWhenSchemeInspectionFails() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let fakeTools = try makeFakeToolEnvironment(scenario: .xcodebuildListFailure)
        try createProfile(
            name: "scheme-inspection-failure",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "scheme-inspection-failure", environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let scheme = try result.check("project.scheme")
        XCTAssertEqual(scheme["status"] as? String, "warn")
        XCTAssertTrue((scheme["message"] as? String)?.contains("xcodebuild -project App.xcodeproj -list -json") == true)
        XCTAssertTrue((scheme["message"] as? String)?.contains("exit 74") == true)
        XCTAssertTrue((scheme["message"] as? String)?.contains("current sandbox") == true)
        XCTAssertFalse((scheme["message"] as? String)?.contains("Scheme is missing") == true)
        let manualAction = scheme["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("outside the current sandbox") == true)
        XCTAssertFalse(manualAction?.contains("Regenerate") == true)

        let destinations = try result.check("project.showdestinations_runnable")
        XCTAssertEqual(destinations["status"] as? String, "pass")
        XCTAssertTrue((destinations["message"] as? String)?.contains("could not be verified") == true)
        let xctestrun = try result.check("project.xctestrun_integrity")
        XCTAssertEqual(xctestrun["status"] as? String, "pass")
        XCTAssertTrue((xctestrun["message"] as? String)?.contains("could not be verified") == true)

        let log = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(log.contains("-list -json"))
        XCTAssertFalse(log.contains("-showdestinations"))
        XCTAssertFalse(log.contains("build-for-testing"))
    }
}
