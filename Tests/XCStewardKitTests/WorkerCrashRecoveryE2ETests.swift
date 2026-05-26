import Darwin
import Foundation
import XCTest
@testable import XCStewardKit

final class WorkerCrashRecoveryE2ETests: XCTestCase {
    func testSubmitWaitClientRecoversDeadWorkerWithoutFollowUpSubmit() throws {
        let e2e = try E2EScenario(scenario: .workerCrashDuringTest)
        try writeCrashRecoveryProfiles(e2e)

        let waitingClient = try startCLI(
            arguments: [
                "submit",
                "--state-root", e2e.stateRoot.path,
                "--project", "demo-crash",
                "--wait",
                "--wait-timeout", "30",
                "--json",
            ],
            environment: e2e.fakeTools.env
        )
        let store = try e2e.stateStore()
        let jobAppeared = try waitUntil(timeout: 5) {
            try !store.listJobs().isEmpty
        }
        XCTAssertTrue(jobAppeared)
        let crashJobID = try XCTUnwrap(try store.listJobs().first?.id)

        let testStarted = try waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: e2e.fakeTools.root.appendingPathComponent("worker-crash-test-started").path)
        }
        let testStartLog = try e2e.toolLog()
        XCTAssertTrue(testStarted, testStartLog)

        let orphanPID = try killWorkerAfterRecordedProcessStarts(e2e: e2e, jobID: crashJobID)
        defer {
            _ = kill(-orphanPID, SIGKILL)
            _ = kill(orphanPID, SIGKILL)
        }

        let result = finishCLI(waitingClient)
        XCTAssertEqual(result.status, 1, result.stderr)
        let summary = try result.jsonObject()
        XCTAssertEqual(summary["job_id"] as? String, crashJobID)
        XCTAssertEqual(summary["state"] as? String, "interrupted")
        XCTAssertEqual(summary["result_class"] as? String, "internal_error")
        XCTAssertEqual(
            summary["summary_line"] as? String,
            "Interrupted: worker process exited before the job completed"
        )
        XCTAssertFalse(isPIDAlive(orphanPID))
        XCTAssertNil(try store.currentLease())
        XCTAssertTrue(try store.listSimulatorLeases().isEmpty)
        let observedTermination = try waitUntil(timeout: 5) {
            try e2e.toolLog().contains("orphaned test received SIGTERM")
        }
        let terminationLog = try e2e.toolLog()
        XCTAssertTrue(observedTermination, terminationLog)
    }

    func testWorkerRestartInterruptsBuildOrphanAndRunsQueuedWork() throws {
        let e2e = try E2EScenario(scenario: .workerCrashDuringBuild)
        try writeCrashRecoveryProfiles(e2e)

        let crashJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-crash"))
        let buildStarted = try waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: e2e.fakeTools.root.appendingPathComponent("worker-crash-build-started").path)
        }
        let buildStartLog = try e2e.toolLog()
        XCTAssertTrue(buildStarted, buildStartLog)

        let orphanPID = try killWorkerAfterRecordedProcessStarts(e2e: e2e, jobID: crashJobID)
        defer {
            _ = kill(-orphanPID, SIGKILL)
            _ = kill(orphanPID, SIGKILL)
        }

        let nextJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-next"))

        let crashStatus = try e2e.waitForStatus(crashJobID, state: "interrupted", timeout: 15)
        XCTAssertEqual(crashStatus["result_class"] as? String, "internal_error")
        XCTAssertEqual(
            crashStatus["summary_line"] as? String,
            "Interrupted: worker process exited before the job completed"
        )
        XCTAssertFalse(isPIDAlive(orphanPID))

        let nextStatus = try e2e.waitForTerminal(nextJobID, timeout: 15)
        XCTAssertEqual(nextStatus["state"] as? String, "succeeded")
        XCTAssertEqual(nextStatus["result_class"] as? String, "success")
        let leasesReleased = try waitUntil(timeout: 5) {
            try e2e.stateStore().listSimulatorLeases().isEmpty
        }
        XCTAssertTrue(leasesReleased)

        let observedTermination = try waitUntil(timeout: 5) {
            try e2e.toolLog().contains("orphaned build received SIGTERM")
        }
        let terminationLog = try e2e.toolLog()
        XCTAssertTrue(observedTermination, terminationLog)
        XCTAssertTrue(try e2e.logs(crashJobID).contains("Interrupted: worker process exited before the job completed"))
    }

    func testWorkerRestartInterruptsTestOrphanAndRunsQueuedWork() throws {
        let e2e = try E2EScenario(scenario: .workerCrashDuringTest)
        try writeCrashRecoveryProfiles(e2e)

        let crashJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-crash"))
        let testStarted = try waitUntil(timeout: 15) {
            FileManager.default.fileExists(atPath: e2e.fakeTools.root.appendingPathComponent("worker-crash-test-started").path)
        }
        let testStartLog = try e2e.toolLog()
        XCTAssertTrue(testStarted, testStartLog)

        let orphanPID = try killWorkerAfterRecordedProcessStarts(e2e: e2e, jobID: crashJobID)
        defer {
            _ = kill(-orphanPID, SIGKILL)
            _ = kill(orphanPID, SIGKILL)
        }

        let nextJobID = try e2e.jobID(from: e2e.submitJSON(project: "demo-next"))

        let crashStatus = try e2e.waitForStatus(crashJobID, state: "interrupted", timeout: 15)
        XCTAssertEqual(crashStatus["result_class"] as? String, "internal_error")
        XCTAssertEqual(
            crashStatus["summary_line"] as? String,
            "Interrupted: worker process exited before the job completed"
        )
        XCTAssertFalse(isPIDAlive(orphanPID))

        let nextStatus = try e2e.waitForTerminal(nextJobID, timeout: 15)
        XCTAssertEqual(nextStatus["state"] as? String, "succeeded")
        XCTAssertEqual(nextStatus["result_class"] as? String, "success")
        let leasesReleased = try waitUntil(timeout: 5) {
            try e2e.stateStore().listSimulatorLeases().isEmpty
        }
        XCTAssertTrue(leasesReleased)

        let observedTermination = try waitUntil(timeout: 5) {
            try e2e.toolLog().contains("orphaned test received SIGTERM")
        }
        let terminationLog = try e2e.toolLog()
        XCTAssertTrue(observedTermination, terminationLog)
        let logs = try e2e.logs(crashJobID)
        XCTAssertTrue(logs.contains("Build succeeded"))
        XCTAssertTrue(logs.contains("Interrupted: worker process exited before the job completed"))
    }

    private func writeCrashRecoveryProfiles(_ e2e: E2EScenario) throws {
        let body = """
        project_path = "App.xcodeproj"
        scheme = "Demo"
        default_simulator_id = "SIM-123"
        """
        try e2e.writeProfile(name: "demo-crash", body: body)
        try e2e.writeProfile(name: "demo-next", body: body)
    }

    private func killWorkerAfterRecordedProcessStarts(e2e: E2EScenario, jobID: String) throws -> Int32 {
        let store = try e2e.stateStore()
        let processTracked = try waitUntil(timeout: 5) {
            try store.fetchJob(id: jobID)?.processID != nil
        }
        let toolLog = try e2e.toolLog()
        XCTAssertTrue(processTracked, toolLog)
        let orphanPID = try XCTUnwrap(store.fetchJob(id: jobID)?.processID)
        let workerPID = try XCTUnwrap(store.currentLease()?.pid)

        XCTAssertEqual(kill(workerPID, SIGKILL), 0)
        let workerExited = try waitUntil(timeout: 5) {
            !isPIDAlive(workerPID)
        }
        XCTAssertTrue(workerExited)
        XCTAssertTrue(isPIDAlive(orphanPID))
        return orphanPID
    }
}
