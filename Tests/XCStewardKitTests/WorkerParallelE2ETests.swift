import Foundation
import Darwin
import XCTest
@testable import XCStewardKit

final class WorkerParallelE2ETests: XCTestCase {
    func testWorkerStartupRecoversUnownedRunningJobAndProcessesQueuedWork() throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )
        let staleJobID = "stale-running"
        let staleJobDirectory = e2e.jobDir(staleJobID)
        try FileManager.default.createDirectory(at: staleJobDirectory, withIntermediateDirectories: true)
        let store = try e2e.stateStore()
        try store.createJob(staleRunningJob(
            id: staleJobID,
            jobDirectory: staleJobDirectory.path,
            simulatorID: "SIM-STALE"
        ))
        XCTAssertTrue(try store.acquireSimulatorLease(simulatorID: "SIM-STALE", jobID: staleJobID, pid: 0))

        let queuedJobID = try e2e.jobID(from: e2e.submitJSON())

        let queuedStatus = try e2e.waitForTerminal(queuedJobID, timeout: 15)
        XCTAssertEqual(queuedStatus["state"] as? String, "succeeded")
        XCTAssertEqual(queuedStatus["result_class"] as? String, "success")

        let staleStatus = try e2e.status(staleJobID)
        XCTAssertEqual(staleStatus["state"] as? String, "interrupted")
        XCTAssertEqual(staleStatus["result_class"] as? String, "internal_error")
        XCTAssertEqual(
            staleStatus["summary_line"] as? String,
            "Interrupted: worker process exited before the job completed"
        )
        XCTAssertTrue(try e2e.stateStore().listSimulatorLeases().isEmpty)
    }

    func testParallelSubmitWaitJSONReturnsIndependentTerminalSummaries() throws {
        let e2e = try E2EScenario(
            scenario: .slowSuccess,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try e2e.writeProfile(
            name: "demo-a",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-A"
            """
        )
        try e2e.writeProfile(
            name: "demo-b",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-B"
            """
        )

        let runs = try ["demo-a", "demo-b"].map { project in
            try startCLI(
                arguments: [
                    "submit",
                    "--state-root", e2e.stateRoot.path,
                    "--project", project,
                    "--wait",
                    "--json",
                ],
                environment: e2e.fakeTools.env
            )
        }
        let results = runs.map(finishCLI(_:))

        let summaries = try results.map { result -> [String: Any] in
            XCTAssertEqual(result.status, 0, result.stderr)
            return try result.jsonObject()
        }
        let jobIDs = Set(try summaries.map { try XCTUnwrap($0["job_id"] as? String) })
        XCTAssertEqual(jobIDs.count, 2)
        XCTAssertEqual(Set(summaries.compactMap { $0["project"] as? String }), ["demo-a", "demo-b"])
        for summary in summaries {
            XCTAssertEqual(summary["state"] as? String, "succeeded")
            XCTAssertEqual(summary["result_class"] as? String, "success")
            let artifacts = try XCTUnwrap(summary["artifacts"] as? [String: Any])
            XCTAssertNotNil(artifacts["xcresult"] as? String)
        }

        let testStartEvents = try e2e.toolEvents().filter { $0.contains("event start phase=test") }
        let toolLog = try e2e.toolLog()
        XCTAssertEqual(testStartEvents.count, 2, toolLog)
    }

    func testInterruptedSubmitWaitClientDoesNotStopBackgroundWorker() throws {
        let e2e = try E2EScenario(scenario: .slowSuccess)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let waitingClient = try startCLI(
            arguments: [
                "submit",
                "--state-root", e2e.stateRoot.path,
                "--project", "demo",
                "--wait",
                "--json",
            ],
            environment: e2e.fakeTools.env
        )
        let store = try e2e.stateStore()
        let jobAppeared = try waitUntil(timeout: 5) {
            try !store.listJobs().isEmpty
        }
        XCTAssertTrue(jobAppeared)
        let jobID = try XCTUnwrap(try store.listJobs().first?.id)

        let workerLeaseAppeared = try waitUntil(timeout: 5) {
            guard let lease = try store.currentLease() else {
                return false
            }
            return lease.pid != waitingClient.process.processIdentifier && isPIDAlive(lease.pid)
        }
        XCTAssertTrue(workerLeaseAppeared)

        try e2e.waitForToolEvents(
            matching: { $0.contains("event start phase=build") },
            count: 1,
            timeout: 15
        )

        XCTAssertEqual(kill(waitingClient.process.processIdentifier, SIGINT), 0)
        let interruptedClient = finishCLI(waitingClient)
        XCTAssertNotEqual(interruptedClient.status, 0)

        let terminal = try e2e.waitForTerminal(jobID, timeout: 20)
        XCTAssertEqual(terminal["state"] as? String, "succeeded")
        XCTAssertEqual(terminal["result_class"] as? String, "success")
        let workerLeaseReleased = try waitUntil(timeout: 5) {
            try store.currentLease() == nil
        }
        XCTAssertTrue(workerLeaseReleased)

        XCTAssertNil(try store.simulatorLease(simulatorID: "SIM-123"))
        let artifacts = try e2e.artifacts(jobID)
        XCTAssertNotNil(artifacts["xcresult"] as? String)
        XCTAssertNotNil(artifacts["combinedLog"] as? String)
        let runMetadata = try XCTUnwrap(
            parseJSON(String(contentsOf: e2e.jobDir(jobID).appendingPathComponent("artifacts/run-metadata.json"))) as? [String: Any]
        )
        XCTAssertEqual(runMetadata["result_class"] as? String, "success")
        XCTAssertEqual(runMetadata["canceled"] as? Bool, false)

        let logs = try e2e.logs(jobID)
        XCTAssertTrue(logs.contains("Build succeeded"))
        XCTAssertTrue(logs.contains("Tests succeeded"))
    }

    func testParallelBurstSubmitCreatesOneDurableRecordPerJob() throws {
        let e2e = try E2EScenario(
            scenario: .success,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "3"]
        )
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let runs = try (0..<10).map { _ in
            try startCLI(
                arguments: [
                    "submit",
                    "--state-root", e2e.stateRoot.path,
                    "--project", "demo",
                    "--json",
                ],
                environment: e2e.fakeTools.env
            )
        }
        let results = runs.map(finishCLI(_:))
        let submittedJobIDs = try Set(results.map { result -> String in
            XCTAssertEqual(result.status, 0, result.stderr)
            return try XCTUnwrap(result.jsonObject()["job_id"] as? String)
        })
        XCTAssertEqual(submittedJobIDs.count, 10)

        for jobID in submittedJobIDs {
            let status = try e2e.waitForTerminal(jobID, timeout: 20)
            XCTAssertEqual(status["state"] as? String, "succeeded")
            XCTAssertEqual(status["result_class"] as? String, "success")
        }

        let jobs = try e2e.stateStore().listJobs()
        XCTAssertEqual(jobs.count, 10)
        XCTAssertEqual(Set(jobs.map(\.id)), submittedJobIDs)
        XCTAssertEqual(jobs.filter { $0.state == .succeeded }.count, 10)
        XCTAssertTrue(try e2e.stateStore().listSimulatorLeases().isEmpty)
    }

    func testConcurrentJobsRecordIndependentOutcomesAndArtifacts() throws {
        let e2e = try E2EScenario(
            scenario: .parallelMixedOutcomes,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try e2e.writeProfile(
            name: "demo-success",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-SUCCESS"
            """
        )
        try e2e.writeProfile(
            name: "demo-artifact",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-ARTIFACT"
            """
        )

        let successJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-success"))
        let artifactJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-artifact"))

        try e2e.waitForToolEvents(
            matching: { $0.contains("event start phase=test") },
            count: 2,
            timeout: 20
        )

        let successStatus = try e2e.waitForTerminal(successJobID, timeout: 30)
        let artifactStatus = try e2e.waitForTerminal(artifactJobID, timeout: 30)
        XCTAssertEqual(successStatus["state"] as? String, "succeeded")
        XCTAssertEqual(successStatus["result_class"] as? String, "success")
        XCTAssertEqual(artifactStatus["state"] as? String, "failed")
        XCTAssertEqual(artifactStatus["result_class"] as? String, "artifact_failure")

        let successArtifacts = try XCTUnwrap(successStatus["artifacts"] as? [String: Any])
        let artifactArtifacts = try XCTUnwrap(artifactStatus["artifacts"] as? [String: Any])
        let successXCResult = try XCTUnwrap(successArtifacts["xcresult"] as? String)
        let artifactXCResult = try XCTUnwrap(artifactArtifacts["xcresult"] as? String)
        XCTAssertNotEqual(successXCResult, artifactXCResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(successXCResult)/summary.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(artifactXCResult)/summary.json"))

        let store = try e2e.stateStore()
        XCTAssertEqual(try store.countRecentInfrastructureFailures(since: 0), 1)
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }

    func testCancelingOneParallelJobDoesNotStopOtherRunningJob() throws {
        let e2e = try E2EScenario(
            scenario: .parallelCancellation,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try e2e.writeProfile(
            name: "demo-keep",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-KEEP"
            """
        )
        try e2e.writeProfile(
            name: "demo-cancel",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-CANCEL"
            """
        )

        let keepJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-keep"))
        let cancelJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-cancel"))

        try e2e.waitForToolEvents(
            matching: { $0.contains("event start phase=test") },
            count: 2,
            timeout: 8
        )

        let store = try e2e.stateStore()
        let cancelProcessTracked = try waitUntil(timeout: 3) {
            try store.fetchJob(id: cancelJobID)?.processID != nil
        }
        XCTAssertTrue(cancelProcessTracked)

        let cancel = try e2e.cancel(cancelJobID)
        XCTAssertEqual(cancel.status, 0, "stderr: \(cancel.stderr)")
        try e2e.writeFakeToolMarker("release-demo-cancel")

        let terminal = try waitUntil(timeout: 15) {
            let keepStatusJSON = try e2e.status(keepJobID)
            let cancelStatusJSON = try e2e.status(cancelJobID)
            return (keepStatusJSON["state"] as? String) == "succeeded" &&
                (cancelStatusJSON["state"] as? String) == "canceled"
        }
        XCTAssertTrue(terminal)

        let keepStatusJSON = try e2e.status(keepJobID)
        let cancelStatusJSON = try e2e.status(cancelJobID)
        XCTAssertEqual(keepStatusJSON["result_class"] as? String, "success")
        XCTAssertEqual(cancelStatusJSON["result_class"] as? String, "canceled")
        let keepArtifacts = try XCTUnwrap(keepStatusJSON["artifacts"] as? [String: Any])
        let keepXCResult = try XCTUnwrap(keepArtifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(keepXCResult)/summary.json"))

        let toolLog = try e2e.toolLog()
        XCTAssertTrue(toolLog.contains("xcodebuild observed cancellation project=demo-cancel"))
        XCTAssertFalse(toolLog.contains("xcodebuild observed cancellation project=demo-keep"))
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }

    func testConcurrentManualShardJobsKeepArtifactsAndLeasesIsolated() throws {
        let e2e = try E2EScenario(
            scenario: .manualShardsConcurrent,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try e2e.writeProfile(
            name: "demo-a",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-A0"
            allowed_simulator_ids = ["SIM-A1"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            """
        )
        try e2e.writeProfile(
            name: "demo-b",
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-B0"
            allowed_simulator_ids = ["SIM-B1"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            """
        )

        let firstJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-a"))
        let secondJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-b"))

        try e2e.waitForToolEvents(
            matching: { $0.contains("event start phase=manual-shard") },
            count: 4,
            timeout: 10
        )

        let store = try e2e.stateStore()
        let activeLeases = Set(try store.listSimulatorLeases().map(\.simulatorID))
        XCTAssertEqual(activeLeases, Set(["SIM-A0", "SIM-A1", "SIM-B0", "SIM-B1"]))

        let bothFinished = try waitUntil(timeout: 20) {
            let firstStatusJSON = try e2e.status(firstJobID)
            let secondStatusJSON = try e2e.status(secondJobID)
            return (firstStatusJSON["state"] as? String) == "succeeded" &&
                (secondStatusJSON["state"] as? String) == "succeeded"
        }
        XCTAssertTrue(bothFinished)

        let firstStatusJSON = try e2e.status(firstJobID)
        let secondStatusJSON = try e2e.status(secondJobID)
        XCTAssertEqual(firstStatusJSON["result_class"] as? String, "success")
        XCTAssertEqual(secondStatusJSON["result_class"] as? String, "success")
        XCTAssertEqual((firstStatusJSON["counts"] as? [String: Any])?["testsRun"] as? Int, 4)
        XCTAssertEqual((secondStatusJSON["counts"] as? [String: Any])?["testsRun"] as? Int, 4)

        let firstShardsPath = e2e.jobDir(firstJobID).appendingPathComponent("artifacts/shards.json")
        let secondShardsPath = e2e.jobDir(secondJobID).appendingPathComponent("artifacts/shards.json")
        let firstSummaryPath = e2e.jobDir(firstJobID).appendingPathComponent("artifacts/combined-summary.json")
        let secondSummaryPath = e2e.jobDir(secondJobID).appendingPathComponent("artifacts/combined-summary.json")
        let firstShards = try XCTUnwrap(parseJSON(String(contentsOf: firstShardsPath)) as? [[String: Any]])
        let secondShards = try XCTUnwrap(parseJSON(String(contentsOf: secondShardsPath)) as? [[String: Any]])
        XCTAssertEqual(firstShards.count, 2)
        XCTAssertEqual(secondShards.count, 2)
        XCTAssertEqual(Set(firstShards.compactMap { $0["simulator_id"] as? String }), Set(["SIM-A0", "SIM-A1"]))
        XCTAssertEqual(Set(secondShards.compactMap { $0["simulator_id"] as? String }), Set(["SIM-B0", "SIM-B1"]))

        let firstResultBundles = Set(firstShards.compactMap { $0["result_bundle"] as? String })
        let secondResultBundles = Set(secondShards.compactMap { $0["result_bundle"] as? String })
        XCTAssertEqual(firstResultBundles.count, 2)
        XCTAssertEqual(secondResultBundles.count, 2)
        XCTAssertTrue(firstResultBundles.isDisjoint(with: secondResultBundles))
        XCTAssertTrue(firstResultBundles.allSatisfy { $0.contains("/jobs/\(firstJobID)/") })
        XCTAssertTrue(secondResultBundles.allSatisfy { $0.contains("/jobs/\(secondJobID)/") })

        let firstSummary = try XCTUnwrap(parseJSON(String(contentsOf: firstSummaryPath)) as? [String: Any])
        let secondSummary = try XCTUnwrap(parseJSON(String(contentsOf: secondSummaryPath)) as? [String: Any])
        XCTAssertEqual(firstSummary["shard_count"] as? Int, 2)
        XCTAssertEqual(secondSummary["shard_count"] as? Int, 2)
        XCTAssertEqual(firstSummary["result_class"] as? String, "success")
        XCTAssertEqual(secondSummary["result_class"] as? String, "success")
        XCTAssertNotEqual(firstSummary["shards_manifest"] as? String, secondSummary["shards_manifest"] as? String)
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
    }
}

private func staleRunningJob(id: String, jobDirectory: String, simulatorID: String) -> JobRecord {
    JobRecord(
        id: id,
        project: "demo",
        state: .running,
        resultClass: nil,
        request: JobRequest(
            project: "demo",
            testPlan: nil,
            onlyTesting: [],
            simulatorID: simulatorID,
            metadata: [:],
            wait: false
        ),
        summary: nil,
        jobDirectory: jobDirectory,
        createdAt: 1,
        startedAt: 2,
        finishedAt: nil,
        processID: nil,
        simulatorID: simulatorID,
        cancelRequested: false
    )
}
