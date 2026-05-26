import Foundation
import XCTest

final class HardeningMatrixTests: XCTestCase {
    private let requiredRows: [(id: String, commandNeedle: String, expectationNeedle: String)] = [
        (
            "submit-10-jobs-at-once",
            "WorkerParallelE2ETests/testParallelBurstSubmitCreatesOneDurableRecordPerJob",
            "Ten concurrent `submit --json` calls create ten unique durable job records"
        ),
        (
            "submit-2-wait-json",
            "WorkerParallelE2ETests/testParallelSubmitWaitJSONReturnsIndependentTerminalSummaries",
            "Two parallel `submit --wait --json` clients each receive the correct terminal JSON"
        ),
        (
            "submit-wait-client-interrupted",
            "WorkerParallelE2ETests/testInterruptedSubmitWaitClientDoesNotStopBackgroundWorker",
            "Interrupting a `submit --wait --json` client leaves the background worker alive"
        ),
        (
            "cancel-queued-job",
            "CancellationE2ETests/testQueuedJobCanBeCanceledWithoutArtifactsOrLeases",
            "Canceling a queued job records terminal `canceled` status with empty artifacts"
        ),
        (
            "same-simulator-lease-serialization",
            "WorkerSchedulingE2ETests/testWorkerSerializesConcurrentJobsOnSameSimulatorLease",
            "Two concurrent jobs targeting the same simulator both succeed"
        ),
        (
            "foreign-simulator-lease-fails-fast",
            "SimulatorLeaseTests/testActiveSimulatorLeaseBlocksAnotherJobForSameUDID",
            "A simulator lease held by an unknown job fails the new job as `runner_bootstrap_failure`"
        ),
        (
            "kill-worker-during-build",
            "WorkerCrashRecoveryE2ETests/testWorkerRestartInterruptsBuildOrphanAndRunsQueuedWork",
            "Worker restart terminates the verified orphan build process group"
        ),
        (
            "kill-worker-during-test",
            "WorkerCrashRecoveryE2ETests/testWorkerRestartInterruptsTestOrphanAndRunsQueuedWork",
            "Worker restart terminates the verified orphan test process group"
        ),
        (
            "simulator-disappears-during-boot",
            "SimulatorHardeningE2ETests/testSimulatorDisappearingDuringBootFailsWithTargetedEvidence",
            "A simulator that disappears during `simctl boot` reports `runner_bootstrap_failure`"
        ),
        (
            "simulator-bootstatus-failure",
            "SimulatorHardeningE2ETests/testBootstatusFailureKeepsEvidenceAndDoesNotRunXcodebuild",
            "A `simctl bootstatus` failure reports `runner_bootstrap_failure`"
        ),
        (
            "cancel-during-simulator-boot",
            "SimulatorHardeningE2ETests/testCancellationDuringSimulatorBootTerminatesBootAndReleasesLease",
            "Canceling during `simctl boot` terminates the owned boot process"
        ),
        (
            "cancel-during-build",
            "CancellationE2ETests/testRunningJobCancellationTerminatesActiveXcodebuildAndRecordsCanceledSummary",
            "Canceling during build terminates the owned `xcodebuild`"
        ),
        (
            "cancel-during-test",
            "CancellationE2ETests/testRunningTestCancellationTerminatesActiveXcodebuildAndRecordsCanceledSummary",
            "Canceling during test terminates the owned test `xcodebuild`"
        ),
        (
            "cancel-during-artifact-parse",
            "CancellationE2ETests/testPostTestArtifactParsingCancellationTerminatesXCResultProbeAndRecordsCanceledSummary",
            "Canceling after tests finish but before `.xcresult` parsing completes"
        ),
        (
            "timeout-during-build",
            "TimeoutHardeningE2ETests/testBuildTimeoutIsClassifiedAndStopsBeforeTestRun",
            "Build timeout reports `build_timeout`"
        ),
        (
            "timeout-during-test",
            "TimeoutHardeningE2ETests/testTestTimeoutIsClassifiedSeparatelyFromRunnerBootstrapFailure",
            "Test timeout reports `test_timeout`"
        ),
        (
            "xcodebuild-exits-65",
            "ExecutionOutcomeE2ETests/testBuildFailureIsClassified",
            "A build exit 65 reports `build_failure`"
        ),
        (
            "isolated-deriveddata-default",
            "SubmitCommandE2ETests/testSubmitWaitSuccessCreatesArtifactsAndStructuredSummary",
            "A successful default job uses the job-local `derived-data` path"
        ),
        (
            "doctor-no-runnable-destination",
            "DoctorProjectPreflightCommandTests/testDoctorFailsWhenNoRunnableIOSSimulatorDestinationExists",
            "Doctor fails with a non-auto-fixable project preflight error when the configured scheme exposes no runnable iOS Simulator destination"
        ),
        (
            "doctor-placeholder-simulator-destination",
            "DoctorProjectPreflightCommandTests/testDoctorRejectsPlaceholderIOSSimulatorDestinationAndSkipsXCTestRunIntegrityBuild",
            "Doctor rejects Xcode's placeholder \"Any iOS Simulator Device\" destination as non-runnable"
        ),
        (
            "doctor-missing-test-plan",
            "DoctorProjectPreflightCommandTests/testDoctorFailsWhenConfiguredTestPlanIsMissing",
            "Doctor fails with a non-auto-fixable project preflight error when the configured test plan is missing"
        ),
        (
            "doctor-deriveddata-override-warning",
            "DoctorProjectPreflightCommandTests/testDoctorWarnsForSharedDerivedDataOverrides",
            "Doctor warns when `DERIVED_DATA_PATH` points inside the repository"
        ),
        (
            "doctor-xcode-managed-parallel-warning",
            "DoctorProjectPreflightCommandTests/testDoctorWarnsWhenXcodeManagedParallelWorkersMayCreateCloneSimulators",
            "Doctor warns when Xcode-managed parallelism can create clone simulators"
        ),
        (
            "doctor-package-resolution-failure",
            "DoctorProjectPreflightCommandTests/testDoctorFailsWhenPackageResolutionPreflightFails",
            "Doctor fails with a non-auto-fixable project preflight error when package dependency resolution fails"
        ),
        (
            "doctor-xctestrun-integrity-failure-evidence",
            "DoctorProjectPreflightCommandTests/testDoctorRetainsBuildForTestingEvidenceWhenXCTestRunIntegrityBuildFails",
            "Doctor retains concise build-for-testing evidence when `.xctestrun` integrity generation fails"
        ),
        (
            "doctor-xctestrun-current-build-required",
            "DoctorProjectPreflightCommandTests/testDoctorRejectsStaleXCTestRunFromIntegrityScratch",
            "Doctor rejects stale `.xctestrun` files from its integrity scratch space"
        ),
        (
            "doctor-xctestrun-integrity-timeout-warning",
            "DoctorProjectPreflightCommandTests/testDoctorWarnsWhenXCTestRunIntegrityBuildTimesOut",
            "Doctor bounds the heavyweight `.xctestrun` integrity build"
        ),
        (
            "doctor-modern-xcresulttool-required",
            "DoctorProjectPreflightCommandTests/testDoctorFailsWhenModernXCResultToolParserIsUnavailable",
            "Doctor fails with a non-auto-fixable preflight error when the selected Xcode lacks the modern `xcresulttool get test-results summary` parser path"
        ),
        (
            "xcresult-missing",
            "ResultArtifactE2ETests/testMissingXCResultAfterSuccessfulTestCommandIsArtifactFailureWithEvidence",
            "A successful test process without a result bundle reports `artifact_failure`"
        ),
        (
            "junit-generation-failure",
            "ResultArtifactE2ETests/testJUnitGenerationFailureAfterSuccessfulTestsIsArtifactFailureWithEvidence",
            "A successful test process whose JUnit path is blocked reports `artifact_failure`"
        ),
        (
            "xcresult-parse-fails",
            "ResultArtifactE2ETests/testSuccessfulTestRunWithCorruptXCResultIsArtifactFailure",
            "A corrupt `.xcresult` reports `artifact_failure`"
        ),
        (
            "retry-enabled",
            "SimulatorBootstrapE2ETests/testBootstrapRetryPreservesFirstAttemptResultBundle",
            "Retry preserves the failed first attempt under `artifacts/attempts/`"
        ),
        (
            "stale-running-job",
            "WorkerParallelE2ETests/testWorkerStartupRecoversUnownedRunningJobAndProcessesQueuedWork",
            "Worker startup reconciles stale running state as `interrupted`"
        ),
        (
            "invalid-simulator-id",
            "SimulatorHardeningE2ETests/testInvalidDefaultSimulatorIDFailsBeforeSimulatorMutation",
            "A missing configured simulator reports `runner_bootstrap_failure`"
        ),
        (
            "read-only-state-root",
            "CommandJSONErrorTests/testReadOnlyStateRootFailureIsStableJSONBeforeQueueMutation",
            "An unavailable state root returns stable `state_root_unavailable` JSON"
        ),
        (
            "state-root-file",
            "CommandJSONErrorTests/testStateRootFileFailureIsStableJSONBeforeQueueMutation",
            "A file-backed state root returns stable `state_root_unavailable` JSON"
        ),
        (
            "corrupt-state-database-path",
            "CommandJSONErrorTests/testCorruptStateDatabasePathFailureIsStableJSONBeforeQueueMutation",
            "A state root whose `state.db` path is a directory returns stable `state_root_unavailable` JSON"
        ),
        (
            "concurrent-state-root-initialization",
            "StateStoreGatewayTests/testConcurrentFreshStateStoreInitializationDoesNotRaceWALSetup",
            "Concurrent first openers for a fresh state root serialize SQLite WAL setup and schema migration"
        ),
        (
            "xcode-unavailable",
            "SimulatorHardeningE2ETests/testXcodebuildUnavailableFailsBeforeSimulatorMutation",
            "Missing `xcodebuild` reports `runner_bootstrap_failure`"
        ),
        (
            "doctor-developer-dir-override-warning",
            "DoctorXcodeEnvironmentCommandTests/testDoctorWarnsWhenDeveloperDirEnvironmentOverridesSelectedXcode",
            "Doctor warns when `DEVELOPER_DIR` overrides `xcode-select`"
        ),
        (
            "doctor-command-line-tools-selected",
            "DoctorXcodeEnvironmentCommandTests/testDoctorFailsWhenSelectedDeveloperDirIsCommandLineTools",
            "Doctor fails with a non-auto-fixable environment error when `xcode-select` points at Command Line Tools"
        ),
        (
            "doctor-first-launch-components-missing",
            "DoctorXcodeEnvironmentCommandTests/testDoctorFailsWhenFirstLaunchComponentsAreMissing",
            "Doctor fails with a non-auto-fixable environment error when first-launch Xcode components are missing"
        ),
        (
            "doctor-xcode-cli-version-mismatch",
            "DoctorXcodeEnvironmentCommandTests/testDoctorFailsWhenSelectedXcodeAndCLICommandVersionsDiffer",
            "Doctor fails with a non-auto-fixable environment error when selected Xcode metadata and `xcodebuild -version` disagree"
        ),
        (
            "doctor-iphonesimulator-sdk-missing",
            "DoctorXcodeEnvironmentCommandTests/testDoctorFailsWhenIPhoneSimulatorSDKIsMissing",
            "Doctor fails with a non-auto-fixable environment error when the selected Xcode does not expose an `iphonesimulator` SDK"
        ),
        (
            "doctor-ios-runtime-missing",
            "DoctorCoreSimulatorCommandTests/testDoctorFailsWhenNoAvailableSimulatorRuntimeIsInstalled",
            "Doctor fails with a non-auto-fixable CoreSimulator environment error when no available iOS Simulator runtime is installed"
        ),
        (
            "doctor-iphonesimulator-sdk-runtime-mismatch",
            "DoctorCoreSimulatorCommandTests/testDoctorFailsWhenIPhoneSimulatorSDKAndRuntimeVersionsDoNotMatch",
            "Doctor fails with a non-auto-fixable environment error when the selected Xcode SDK and installed iOS Simulator runtime do not match"
        ),
        (
            "doctor-unavailable-runtime-warning",
            "DoctorCoreSimulatorCommandTests/testDoctorWarnsWhenInstalledSimulatorRuntimeIsUnavailable",
            "Doctor warns when installed iOS Simulator runtimes are unavailable"
        ),
        (
            "doctor-runtime-availability-parser-variants",
            "DoctorCoreSimulatorCommandTests/testDoctorParsesTextualSimulatorRuntimeAvailability",
            "Runtime availability parsing handles textual, numeric, and string flags conservatively"
        ),
        (
            "doctor-runtime-dyld-cache-error",
            "DoctorCoreSimulatorCommandTests/testDoctorFailsWhenSimulatorRuntimeReportsDyldCacheError",
            "Doctor fails with a non-auto-fixable CoreSimulator environment error when an iOS runtime reports dyld cache errors"
        ),
        (
            "doctor-coresim-json-health-failure",
            "DoctorCoreSimulatorCommandTests/testDoctorFailsWhenCoreSimulatorJsonEnumerationHangs",
            "Doctor fails with a non-auto-fixable CoreSimulator health error when `simctl list --json` cannot return promptly"
        ),
        (
            "doctor-unavailable-device-inspection-failure",
            "DoctorCoreSimulatorCommandTests/testDoctorWarnsWithoutAutoFixWhenUnavailableDeviceInspectionFails",
            "Doctor warns without marking the check auto-fixable when unavailable Simulator devices cannot be inspected"
        ),
        (
            "doctor-unavailable-device-parser-variants",
            "DoctorCoreSimulatorCommandTests/testDoctorWarnsWhenTextualUnavailableSimulatorDevicesExist",
            "Unavailable-device parsing recognizes textual, snake-case, numeric, and string availability variants"
        ),
        (
            "host-capacity-recovers",
            "WorkerSchedulingE2ETests/testWorkerRunsQueuedJobsAfterInfrastructureDrainWindowClears",
            "Infrastructure drain keeps jobs queued while capacity is unavailable"
        ),
        (
            "doctor-competing-runner-process-warning",
            "DoctorStateHealthCommandTests/testDoctorWarnsWhenCompetingLocalRunnerProcessesAreDetected",
            "Doctor warns when unrelated local `xcodebuild`, `xctest`, or `simctl` activity is detected"
        ),
        (
            "doctor-process-listing-unavailable",
            "DoctorStateHealthCommandTests/testDoctorWarnsWhenProcessListingProbeCannotRun",
            "Doctor warns when it cannot inspect local runner processes"
        ),
        (
            "doctor-state-root-protected-path-warning",
            "DoctorPathSafetyCommandTests/testDoctorWarnsWhenStateRootIsUnderProtectedPath",
            "Doctor warns when the XCSteward state root is under a protected or high-risk path"
        ),
        (
            "doctor-project-protected-path-warning",
            "DoctorPathSafetyCommandTests/testDoctorWarnsWhenProjectProfilePathsAreProtected",
            "Doctor warns when project profile repo, project/workspace, or explicit build-output paths"
        ),
        (
            "doctor-fix-narrow-by-default",
            "DoctorCoreSimulatorCommandTests/testDoctorFixDoesNotDeleteUnavailableSimulatorDevices",
            "Plain `doctor --fix --json` reports unavailable Simulator devices as still unfixed"
        ),
        (
            "doctor-managed-simulator-fix-scoped",
            "DoctorManagedSimulatorCommandTests/testDoctorFixCreatesManagedSimulatorAndRecoversStaleLease",
            "Project-scoped `doctor --fix --json` creates only the configured managed simulator"
        ),
        (
            "global-coresimulator-cleanup-confirmation",
            "DoctorCoreSimulatorCommandTests/testDoctorFixGlobalRequiresDangerConfirmationBeforeDeletingUnavailableSimulatorDevices",
            "Unconfirmed `doctor --fix-global --json` returns a usage error"
        ),
        (
            "cleanup-state-root-containment",
            "CleanupCommandTests/testCleanupServiceSkipsSymlinkedJobDirectoryResolvingOutsideJobsRoot",
            "Cleanup skips a terminal job whose recorded job directory is textually under `jobs/`"
        ),
        (
            "process-monitoring-error",
            "ProcessMonitoringRecoveryTests/testWorkerRecordsInternalFailureWhenBuildProcessMonitoringFails",
            "An ambiguous process-monitoring error during build records a failed `internal_error` job"
        ),
        (
            "foreign-live-process-preserved",
            "StateStoreGatewayTests/testRecoveryDoesNotTerminateUnrelatedLiveRecordedProcess",
            "Stale worker recovery does not terminate a distinct live recorded process"
        ),
        (
            "malformed-profile-fails-before-mutation",
            "ProfileFailureRecoveryTests/testMalformedProfileFailsBeforeToolOrSimulatorMutationWithEvidence",
            "A malformed project profile records a failed `runner_bootstrap_failure`"
        ),
        (
            "live-xcode-managed-smoke",
            "LiveXcodeManagedParallelSmokeTests/testLiveXcodeManagedParallelSmoke",
            "A real simulator run succeeds"
        ),
    ]

    func testHardeningMatrixDocumentsEveryPublicAlphaGateWithRunnableCommandAndExpectedResult() throws {
        let text = try String(contentsOf: matrixURL())
        XCTAssertFalse(text.localizedCaseInsensitiveContains("does not crash"))

        for row in requiredRows {
            XCTAssertTrue(text.contains("| `\(row.id)` |"), "Missing matrix row \(row.id)")
            XCTAssertTrue(text.contains(row.commandNeedle), "Missing command for \(row.id)")
            XCTAssertTrue(text.contains(row.expectationNeedle), "Missing specific expected result for \(row.id)")
        }

        XCTAssertTrue(text.contains("XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1"))
        XCTAssertTrue(text.contains("XCSTEWARD_LIVE_SIMULATOR_ID=<simulator-udid>"))
        XCTAssertTrue(text.contains("--continue-on-failure"))
        XCTAssertTrue(text.contains("Public alpha requires all fake-tool rows to pass"))
    }

    func testHardeningMatrixManifestHasNoDuplicateRows() throws {
        let rowIDs = try matrixRowIDs()
        XCTAssertEqual(Set(rowIDs).count, rowIDs.count, "Hardening matrix row IDs must be unique")
        XCTAssertEqual(rowIDs, requiredRows.map(\.id), "Matrix row order must match the release-gate test manifest")
    }

    func testHardeningMatrixRunnerListsFakeRowsAndSkipsLiveSmokeByDefault() throws {
        let result = try runHardeningMatrixScript(arguments: ["--list"])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("submit-10-jobs-at-once"))
        XCTAssertTrue(result.stdout.contains("doctor-coresim-json-health-failure"))
        XCTAssertFalse(result.stdout.contains("live-xcode-managed-smoke"))
        XCTAssertTrue(result.stderr.contains("live-xcode-managed-smoke skipped"))
    }

    func testHardeningMatrixRunnerListsExactlyDocumentedFakeRows() throws {
        let result = try runHardeningMatrixScript(arguments: ["--list"])

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let listedIDs = result.stdout
            .split(separator: "\n")
            .map { line in
                String(line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)[0])
            }
        let expectedIDs = requiredRows
            .map(\.id)
            .filter { $0 != "live-xcode-managed-smoke" }

        XCTAssertEqual(Set(listedIDs).count, listedIDs.count, "Matrix runner listed duplicate rows")
        XCTAssertEqual(listedIDs, expectedIDs)
    }

    func testHardeningMatrixRunnerExecutesSelectedFakeRow() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        let log = temp.appendingPathComponent("swift.log")
        let report = temp.appendingPathComponent("report.json")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' "$*" >> "${FAKE_SWIFT_LOG:?missing fake swift log}"
            exit 0
            """,
            to: bin.appendingPathComponent("swift")
        )

        let path = "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        let result = try runHardeningMatrixScript(
            arguments: ["--row", "doctor-coresim-json-health-failure", "--report", report.path],
            environment: [
                "PATH": path,
                "FAKE_SWIFT_LOG": log.path,
            ]
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("[1/1] doctor-coresim-json-health-failure"))
        XCTAssertTrue(result.stdout.contains("Hardening matrix report: \(report.path)"))
        XCTAssertTrue(result.stdout.contains("Hardening matrix passed: 1 row(s)"))

        let swiftLog = try String(contentsOf: log)
        XCTAssertTrue(swiftLog.contains("--disable-sandbox"))
        XCTAssertTrue(swiftLog.contains("--cache-path"))
        XCTAssertTrue(swiftLog.contains("--filter DoctorCoreSimulatorCommandTests/testDoctorFailsWhenCoreSimulatorJsonEnumerationHangs"))
        XCTAssertFalse(swiftLog.contains("LiveXcodeManagedParallelSmokeTests"))

        let reportJSON = try XCTUnwrap(parseJSON(try String(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportJSON["status"] as? String, "passed")
        XCTAssertEqual(reportJSON["live_included"] as? Bool, false)
        XCTAssertEqual(reportJSON["live_skipped"] as? Bool, false)
        XCTAssertEqual(reportJSON["continue_on_failure"] as? Bool, false)
        XCTAssertEqual(reportJSON["failed_count"] as? Int, 0)
        let rows = try XCTUnwrap(reportJSON["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"] as? String, "doctor-coresim-json-health-failure")
        XCTAssertEqual(rows[0]["status"] as? String, "passed")
        XCTAssertEqual(rows[0]["exit_code"] as? Int, 0)
        XCTAssertTrue((rows[0]["command"] as? String)?.contains("--disable-sandbox") == true)
    }

    func testHardeningMatrixRunnerWritesFailureReport() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        let report = temp.appendingPathComponent("failure-report.json")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            exit 7
            """,
            to: bin.appendingPathComponent("swift")
        )

        let path = "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        let result = try runHardeningMatrixScript(
            arguments: ["--row", "doctor-coresim-json-health-failure", "--report", report.path],
            environment: ["PATH": path]
        )

        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.stdout.contains("Hardening matrix report: \(report.path)"))

        let reportJSON = try XCTUnwrap(parseJSON(try String(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportJSON["status"] as? String, "failed")
        XCTAssertEqual(reportJSON["continue_on_failure"] as? Bool, false)
        XCTAssertEqual(reportJSON["failed_count"] as? Int, 1)
        let rows = try XCTUnwrap(reportJSON["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"] as? String, "doctor-coresim-json-health-failure")
        XCTAssertEqual(rows[0]["status"] as? String, "failed")
        XCTAssertEqual(rows[0]["exit_code"] as? Int, 7)
    }

    func testHardeningMatrixRunnerCanContinueAfterFailuresAndReportAllRows() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        let log = temp.appendingPathComponent("swift.log")
        let matrix = temp.appendingPathComponent("matrix.md")
        let report = temp.appendingPathComponent("continue-report.json")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeText(
            """
            | Row ID | Command | Expected Result |
            | --- | --- | --- |
            | `first-fails` | `swift test --filter FirstFailure` | Failure row is reported. |
            | `second-passes` | `swift test --filter SecondPass` | Later row still runs. |
            """,
            to: matrix
        )
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' "$*" >> "${FAKE_SWIFT_LOG:?missing fake swift log}"
            case "$*" in
              *FirstFailure*) exit 7 ;;
              *) exit 0 ;;
            esac
            """,
            to: bin.appendingPathComponent("swift")
        )

        let path = "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        let result = try runHardeningMatrixScript(
            arguments: ["--continue-on-failure", "--report", report.path],
            environment: [
                "PATH": path,
                "FAKE_SWIFT_LOG": log.path,
                "XCSTEWARD_HARDENING_MATRIX_FILE": matrix.path,
            ]
        )

        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.stdout.contains("[1/2] first-fails"))
        XCTAssertTrue(result.stdout.contains("[2/2] second-passes"))
        XCTAssertTrue(result.stdout.contains("Hardening matrix report: \(report.path)"))
        XCTAssertTrue(result.stdout.contains("Hardening matrix failed: 1 row(s) failed"))

        let swiftLog = try String(contentsOf: log)
        XCTAssertTrue(swiftLog.contains("--filter FirstFailure"))
        XCTAssertTrue(swiftLog.contains("--filter SecondPass"))

        let reportJSON = try XCTUnwrap(parseJSON(try String(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportJSON["status"] as? String, "failed")
        XCTAssertEqual(reportJSON["continue_on_failure"] as? Bool, true)
        XCTAssertEqual(reportJSON["failed_count"] as? Int, 1)
        let rows = try XCTUnwrap(reportJSON["rows"] as? [[String: Any]])
        guard rows.count == 2 else {
            XCTFail("Expected two reported rows, got \(rows.count): \(result.stdout)")
            return
        }
        XCTAssertEqual(rows[0]["id"] as? String, "first-fails")
        XCTAssertEqual(rows[0]["status"] as? String, "failed")
        XCTAssertEqual(rows[0]["exit_code"] as? Int, 7)
        XCTAssertEqual(rows[1]["id"] as? String, "second-passes")
        XCTAssertEqual(rows[1]["status"] as? String, "passed")
        XCTAssertEqual(rows[1]["exit_code"] as? Int, 0)
    }

    func testHardeningMatrixRunnerRejectsUnsafeShellCommandsBeforeExecution() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        let log = temp.appendingPathComponent("swift.log")
        let matrix = temp.appendingPathComponent("matrix.md")
        let report = temp.appendingPathComponent("unsafe-report.json")
        let injectedFile = temp.appendingPathComponent("injected")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeText(
            """
            | Row ID | Command | Expected Result |
            | --- | --- | --- |
            | `unsafe-shell` | `swift test --filter Safe; touch \(injectedFile.path)` | Shell metacharacters are rejected before execution. |
            """,
            to: matrix
        )
        try writeExecutable(
            """
            #!/bin/sh
            printf 'invoked\\n' >> "${FAKE_SWIFT_LOG:?missing fake swift log}"
            exit 0
            """,
            to: bin.appendingPathComponent("swift")
        )

        let path = "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        let result = try runHardeningMatrixScript(
            arguments: ["--report", report.path],
            environment: [
                "PATH": path,
                "FAKE_SWIFT_LOG": log.path,
                "XCSTEWARD_HARDENING_MATRIX_FILE": matrix.path,
            ]
        )

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("unsafe or unsupported command for row 'unsafe-shell'"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: injectedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
    }

    func testHardeningMatrixRunnerExecutesLiveSmokeRowOnlyWhenExplicitlyIncluded() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        let log = temp.appendingPathComponent("swift.log")
        let report = temp.appendingPathComponent("live-report.json")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf 'live=%s\\n' "${XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE:-}" >> "${FAKE_SWIFT_LOG:?missing fake swift log}"
            printf 'args=%s\\n' "$*" >> "${FAKE_SWIFT_LOG:?missing fake swift log}"
            exit 0
            """,
            to: bin.appendingPathComponent("swift")
        )

        let path = "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"
        let result = try runHardeningMatrixScript(
            arguments: ["--row", "live-xcode-managed-smoke", "--include-live", "--report", report.path],
            environment: [
                "PATH": path,
                "FAKE_SWIFT_LOG": log.path,
                "XCSTEWARD_LIVE_SIMULATOR_ID": "FAKE-LIVE-SIM",
            ]
        )

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("[1/1] live-xcode-managed-smoke"))
        XCTAssertTrue(result.stdout.contains("Hardening matrix passed: 1 row(s)"))

        let swiftLog = try String(contentsOf: log)
        XCTAssertTrue(swiftLog.contains("live=1"))
        XCTAssertTrue(swiftLog.contains("--filter LiveXcodeManagedParallelSmokeTests/testLiveXcodeManagedParallelSmoke"))

        let reportJSON = try XCTUnwrap(parseJSON(try String(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(reportJSON["status"] as? String, "passed")
        XCTAssertEqual(reportJSON["live_included"] as? Bool, true)
        XCTAssertEqual(reportJSON["live_skipped"] as? Bool, false)
        let rows = try XCTUnwrap(reportJSON["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"] as? String, "live-xcode-managed-smoke")
        XCTAssertEqual(rows[0]["status"] as? String, "passed")
        XCTAssertTrue((rows[0]["command"] as? String)?.contains("XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1") == true)
    }

    private func matrixURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/hardening-matrix.md")
    }

    private func matrixRowIDs() throws -> [String] {
        let text = try String(contentsOf: matrixURL())
        return text
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("| `") else {
                    return nil
                }
                let columns = line.split(separator: "|", omittingEmptySubsequences: false)
                guard columns.count > 1 else {
                    return nil
                }
                let rawID = columns[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard rawID.hasPrefix("`"), rawID.hasSuffix("`") else {
                    return nil
                }
                return String(rawID.dropFirst().dropLast())
            }
    }

    private func runHardeningMatrixScript(
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> CLIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["scripts/run-hardening-matrix.sh"] + arguments
        process.currentDirectoryURL = repoRootURL()
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return CLIResult(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
