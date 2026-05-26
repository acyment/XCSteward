import Foundation
import XCTest
@testable import XCStewardKit

final class ManualShardE2ETests: XCTestCase {
    func testManualShardRunProducesDiagnosticsAndShardResultBundles() throws {
        let e2e = try E2EScenario(scenario: .manualShards)
        try writeManualShardProfile(
            in: e2e,
            extraBody: """
            [ports]
            base = 52000
            count = 4
            stride = 10
            """
        )

        let json = try e2e.submitJSON(wait: true)
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        XCTAssertEqual(json["summary_line"] as? String, "Manual shards succeeded (2 shards)")
        XCTAssertEqual((json["counts"] as? [String: Any])?["testsRun"] as? Int, 4)

        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let mergedXCResult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(mergedXCResult)/summary.json"))

        let diagnostics = try e2e.manualRunDiagnostics(from: artifacts)
        XCTAssertEqual(diagnostics.summary["result_class"] as? String, "success")
        XCTAssertEqual(diagnostics.summary["shard_count"] as? Int, 2)
        XCTAssertEqual(diagnostics.summary["retry_count"] as? Int, 0)
        XCTAssertEqual(diagnostics.summary["merged_result_bundle"] as? String, mergedXCResult)
        XCTAssertEqual(diagnostics.shards.count, 2)
        for report in diagnostics.shards {
            let resultBundle = try XCTUnwrap(report["result_bundle"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(resultBundle)/summary.json"))
            XCTAssertEqual((report["only_testing"] as? [String])?.count, 2)
        }

        let junitPath = try XCTUnwrap(artifacts["junit"] as? String)
        let junit = try String(contentsOfFile: junitPath)
        XCTAssertTrue(junit.contains("tests=\"4\""))
        XCTAssertTrue(junit.contains("failures=\"0\""))
        XCTAssertTrue(junit.contains("DemoTests.FooTests"))
        XCTAssertTrue(junit.contains("name=\"testA\""))

        let jobID = try e2e.jobID(from: json)
        let jobDir = e2e.jobDir(jobID)
        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_JOB_ID=\(jobID)"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PROJECT=demo"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_MODE=manual-shards"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PHASE=enumerate-tests"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PHASE=manual-shard"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_SHARD_ID=shard-000"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_SHARD_ID=shard-001"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_SHARD_INDEX=0"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_SHARD_INDEX=1"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_TOTAL_SHARDS=2"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PORT_RANGE_INDEX=0"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PORT_RANGE_INDEX=1"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PORT_RANGE=52000-52003"))
        XCTAssertTrue(toolLog.contains("env TEST_RUNNER_XCSTEWARD_PORT_RANGE=52010-52013"))
        XCTAssertTrue(toolLog.contains("env TMPDIR=\(jobDir.appendingPathComponent("artifacts/shards/shard-000/tmp").path)"))
        XCTAssertTrue(toolLog.contains("env TMPDIR=\(jobDir.appendingPathComponent("artifacts/shards/shard-001/tmp").path)"))

        let shardsManifest = try XCTUnwrap(diagnostics.summary["shards_manifest"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shardsManifest))
        let shardLines = try e2e.xcodebuildLines(containing: "test-without-building")
            .filter { !$0.contains("-enumerate-tests") }
        let enumerateLine = try XCTUnwrap(try e2e.xcodebuildLines(containing: "-enumerate-tests").first)
        XCTAssertTrue(enumerateLine.contains("-test-enumeration-output-path"))
        XCTAssertEqual(shardLines.count, 2)
        XCTAssertTrue(shardLines.contains { $0.contains("-destination id=SIM-123") })
        XCTAssertTrue(shardLines.contains { $0.contains("-destination id=SIM-456") })
        XCTAssertTrue(toolLog.contains("xcrun xcresulttool merge"))
        XCTAssertTrue(toolLog.contains("--output-path \(mergedXCResult)"))
        for line in shardLines {
            XCTAssertTrue(line.contains("-parallel-testing-enabled NO"))
            XCTAssertTrue(line.contains("-maximum-parallel-testing-workers 1"))
            XCTAssertFalse(line.contains("-parallel-testing-worker-count"))
            XCTAssertTrue(line.contains("-test-timeouts-enabled YES"))
            XCTAssertTrue(line.contains("-default-test-execution-time-allowance 120"))
            XCTAssertTrue(line.contains("-maximum-test-execution-time-allowance 600"))
            XCTAssertTrue(line.contains("-only-testing:"))
        }
    }

    func testManualShardFatalFailureTerminatesPeerShard() throws {
        let e2e = try E2EScenario(scenario: .manualShardFatalShortCircuit)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-456"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            """
        )

        let json = try e2e.submitJSON(wait: true)

        XCTAssertEqual(json["state"] as? String, "failed")
        XCTAssertEqual(json["result_class"] as? String, "runner_bootstrap_failure")
        let jobID = try e2e.jobID(from: json)
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let diagnostics = try e2e.manualRunDiagnostics(from: artifacts)
        XCTAssertTrue(diagnostics.shards.contains { $0["result_class"] as? String == "runner_bootstrap_failure" })
        XCTAssertTrue(try e2e.logs(jobID).contains("Stopping manual shard peers after shard-000 produced runner_bootstrap_failure"))
    }

    func testManualShardsCanUseTestProductsRuntime() throws {
        let e2e = try E2EScenario(scenario: .manualShards)
        try writeManualShardProfile(
            in: e2e,
            extraBody: """
            [test_products]
            enabled = true
            use_for_testing = true
            """
        )

        let json = try e2e.submitJSON(wait: true)

        let jobID = try e2e.jobID(from: json)
        let testProducts = e2e.jobDir(jobID)
            .appendingPathComponent("artifacts/test-products.xctestproducts")
        let enumerationLine = try XCTUnwrap(try e2e.xcodebuildLines(containing: "-enumerate-tests").first)
        XCTAssertTrue(enumerationLine.contains("-testProductsPath \(testProducts.path)"))
        XCTAssertFalse(enumerationLine.contains("-xctestrun"))
        let shardLines = try e2e.xcodebuildLines(containing: "test-without-building")
            .filter { !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        for line in shardLines {
            XCTAssertTrue(line.contains("-testProductsPath \(testProducts.path)"))
            XCTAssertFalse(line.contains("-xctestrun"))
        }
    }

    func testManualShardsApplyConfiguredPrivacyToEachShardSimulator() throws {
        let e2e = try E2EScenario(scenario: .manualShards)
        try writeManualShardProfile(
            in: e2e,
            extraBody: """
            [privacy]
            grant = ["photos:com.example.Demo"]
            """
        )

        let json = try e2e.submitJSON(wait: true)
        XCTAssertEqual(json["result_class"] as? String, "success")

        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun simctl privacy SIM-123 grant photos com.example.Demo"))
        XCTAssertTrue(toolLog.contains("xcrun simctl privacy SIM-456 grant photos com.example.Demo"))
    }

    func testManualShardsKeepPerShardBundlesWhenMergeFails() throws {
        let e2e = try E2EScenario(scenario: .manualShardMergeFailure)
        try writeManualShardProfile(in: e2e)

        let json = try e2e.submitJSON(wait: true)

        XCTAssertEqual(json["result_class"] as? String, "success")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        XCTAssertTrue(artifacts["xcresult"] == nil || artifacts["xcresult"] is NSNull)
        let diagnostics = try e2e.manualRunDiagnostics(from: artifacts)
        XCTAssertEqual(diagnostics.summary["result_class"] as? String, "success")
        XCTAssertEqual(diagnostics.summary["shard_count"] as? Int, 2)
        XCTAssertTrue(diagnostics.summary["merged_result_bundle"] == nil || diagnostics.summary["merged_result_bundle"] is NSNull)
        XCTAssertEqual(diagnostics.shards.count, 2)
        for report in diagnostics.shards {
            let resultBundle = try XCTUnwrap(report["result_bundle"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(resultBundle)/summary.json"))
        }
        let jobID = try e2e.jobID(from: json)
        let combinedLog = try String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("logs/combined.log"))
        XCTAssertTrue(combinedLog.contains("WARNING: Unable to merge shard result bundles"))
    }

    func testManualShardsRequireEnoughConfiguredSimulatorIDs() throws {
        let e2e = try E2EScenario(scenario: .manualShards)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            """
        )

        let result = try e2e.submit(wait: true)
        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertTrue((json["summary_line"] as? String)?.contains("manual-shards requires 2 simulator IDs") == true)
    }

    func testManualShardsCloneManagedSimulatorWhenConfiguredIDsAreInsufficient() throws {
        let e2e = try E2EScenario(scenario: .manualShards)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [managed_simulator]
            name = "iPhone 17 Pro"
            device_type = "iPhone 17 Pro"
            runtime = "iOS 18.0"
            clone_for_shards = true
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            """
        )

        let json = try e2e.submitJSON(wait: true)

        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["simulator_id"] as? String, "SIM-123")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let reports = try e2e.manualRunDiagnostics(from: artifacts).shards
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue(reports.contains { ($0["simulator_id"] as? String) == "SIM-123" })
        XCTAssertTrue(reports.contains { ($0["simulator_id"] as? String) == "00000000-0000-0000-0000-000000000456" })

        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl clone SIM-123 iPhone 17 Pro-xcsteward-"))
        XCTAssertTrue(toolLog.contains("xcrun simctl boot 00000000-0000-0000-0000-000000000456"))
        XCTAssertTrue(toolLog.contains("xcrun simctl delete 00000000-0000-0000-0000-000000000456"))
        XCTAssertFalse(toolLog.contains("xcrun simctl delete SIM-123"))
    }

    func testManualShardRetriesBootstrapFailureAndRecordsRetryDiagnostics() throws {
        let e2e = try E2EScenario(scenario: .manualShardBootstrapRetry)
        try writeManualShardProfile(in: e2e)

        let json = try e2e.submitJSON(wait: true)

        XCTAssertEqual(json["result_class"] as? String, "success")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let diagnostics = try e2e.manualRunDiagnostics(from: artifacts)
        XCTAssertEqual(diagnostics.summary["retry_count"] as? Int, 1)
        let aggregateDiagnostics = try XCTUnwrap(diagnostics.summary["simulator_diagnostics"] as? [String])
        XCTAssertEqual(aggregateDiagnostics.count, 1)
        XCTAssertEqual(diagnostics.shards.count, 2)
        XCTAssertTrue(diagnostics.shards.contains {
            ($0["attempts"] as? Int) == 2 &&
                ($0["retry_reason"] as? String) == "runner_bootstrap_failure"
        })
        XCTAssertTrue(diagnostics.shards.contains { ($0["attempts"] as? Int) == 1 })
        let retriedReport = try XCTUnwrap(diagnostics.shards.first { ($0["attempts"] as? Int) == 2 })
        let shardDiagnostics = try XCTUnwrap(retriedReport["simulator_diagnostics"] as? [String])
        XCTAssertEqual(shardDiagnostics, aggregateDiagnostics)
        let diagnoseLog = try String(contentsOfFile: try XCTUnwrap(shardDiagnostics.first))
        XCTAssertTrue(diagnoseLog.contains("command=xcrun simctl diagnose -l"))
        XCTAssertTrue(diagnoseLog.contains("CoreSimulatorDiagnostic"))

        let toolLog = try e2e.toolLog()
        let testInvocations = toolLog
            .split(separator: "\n")
            .filter { $0.contains("test-without-building") && !$0.contains("-enumerate-tests") }
        XCTAssertEqual(testInvocations.count, 3)
        XCTAssertTrue(toolLog.contains("xcrun simctl diagnose -l"))
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown"))
        XCTAssertTrue(toolLog.contains("xcrun simctl erase"))

        let jobID = try e2e.jobID(from: json)
        let combinedLog = try String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("logs/combined.log"))
        XCTAssertTrue(combinedLog.contains("WARNING: Retrying shard-"))
        XCTAssertEqual(try e2e.stateStore().countRecentInfrastructureFailures(since: 0), 1)
    }

    func testManualShardRetryPreservesFirstAttemptResultBundle() throws {
        let e2e = try E2EScenario(scenario: .manualShardBootstrapRetryWithPartialResult)
        try writeManualShardProfile(in: e2e)

        let json = try e2e.submitJSON(wait: true)

        XCTAssertEqual(json["result_class"] as? String, "success")
        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let diagnostics = try e2e.manualRunDiagnostics(from: artifacts)
        let retriedReport = try XCTUnwrap(diagnostics.shards.first { ($0["attempts"] as? Int) == 2 })
        let attemptArtifacts = try XCTUnwrap(retriedReport["attempt_artifacts"] as? [[String: Any]])
        XCTAssertEqual(attemptArtifacts.count, 1)
        let attempt = try XCTUnwrap(attemptArtifacts.first)
        XCTAssertEqual(attempt["phase"] as? String, "manual-shard")
        XCTAssertEqual(attempt["result_class"] as? String, "runner_bootstrap_failure")
        XCTAssertEqual(attempt["retry_reason"] as? String, "runner_bootstrap_failure")

        let firstAttemptBundle = try XCTUnwrap(attempt["result_bundle"] as? String)
        let finalBundle = try XCTUnwrap(retriedReport["result_bundle"] as? String)
        XCTAssertNotEqual(firstAttemptBundle, finalBundle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: firstAttemptBundle).appendingPathComponent("summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: finalBundle).appendingPathComponent("summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(attempt["metadata"] as? String)))
    }

    func testManualShardsUseHistoricalTimingsToBalanceFutureRuns() throws {
        let e2e = try E2EScenario(scenario: .manualShards)
        try writeManualShardProfile(in: e2e)

        func runAndLoadShardReports() throws -> [[String: Any]] {
            let json = try e2e.submitJSON(wait: true)
            let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
            return try e2e.manualRunDiagnostics(from: artifacts).shards
        }

        _ = try runAndLoadShardReports()
        let secondReports = try runAndLoadShardReports()
        let groups = secondReports.map { report in
            Set((report["only_testing"] as? [String]) ?? [])
        }
        XCTAssertTrue(
            groups.contains(Set(["DemoTests/FooTests/testA"])),
            "groups: \(groups)"
        )
        XCTAssertTrue(groups.contains(Set([
            "DemoTests/FooTests/testB",
            "DemoTests/BarTests/testC",
            "DemoTests/BarTests/testD",
        ])), "groups: \(groups)")
    }

    func testHybridParallelModeRunsManualShardsWithInnerXcodeManagedWorkers() throws {
        let e2e = try E2EScenario(scenario: .manualShards)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            [parallel]
            mode = "hybrid"
            shard_count = 2
            max_workers = 2
            exact_workers = false
            """
        )

        let json = try e2e.submitJSON(wait: true)

        XCTAssertEqual(json["result_class"] as? String, "success")
        XCTAssertEqual(json["summary_line"] as? String, "Hybrid shards succeeded (2 shards)")
        let shardLines = try e2e.xcodebuildLines(containing: "test-without-building")
            .filter { !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        for line in shardLines {
            XCTAssertTrue(line.contains("-parallel-testing-enabled YES"))
            XCTAssertTrue(line.contains("-maximum-parallel-testing-workers 2"))
            XCTAssertFalse(line.contains("-parallel-testing-worker-count"))
        }
    }

    func testResetPolicyEraseCleansAllManualShardSimulatorsAfterJob() throws {
        let e2e = try E2EScenario(scenario: .manualShards)
        try writeManualShardProfile(
            in: e2e,
            extraBody: """
            reset_policy = "erase"
            """
        )

        let json = try e2e.submitJSON(wait: true)
        XCTAssertEqual(json["result_class"] as? String, "success")

        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl erase SIM-123"))
        XCTAssertTrue(toolLog.contains("xcrun simctl shutdown SIM-456"))
        XCTAssertTrue(toolLog.contains("xcrun simctl erase SIM-456"))
        XCTAssertFalse(toolLog.contains("erase all"))
    }

    private func writeManualShardProfile(
        in e2e: E2EScenario,
        extraBody: String = ""
    ) throws {
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            \(extraBody)
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            """
        )
    }
}
