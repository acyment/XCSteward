import Foundation
import XCTest
@testable import XCStewardKit

final class WorkerSchedulingE2ETests: XCTestCase {
    func testWorkerRunsDifferentSimulatorJobsConcurrentlyWhenBudgetAllows() throws {
        let e2e = try E2EScenario(
            scenario: .slowSuccess,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try writeProfiles([
            (name: "demo-a", simulatorID: "SIM-A"),
            (name: "demo-b", simulatorID: "SIM-B"),
        ], in: e2e)

        let jobIDs = try submitJobIDs(["demo-a", "demo-b"], in: e2e)

        let bothBuildsStarted = try waitUntil(timeout: 10) {
            try e2e.toolLog().components(separatedBy: "build-for-testing").count - 1 >= 2
        }
        let buildLog = try e2e.toolLog()
        XCTAssertTrue(bothBuildsStarted, buildLog)

        try waitForEventCount(in: e2e, containing: "event start phase=test", atLeast: 2, timeout: 20)
        try waitForSuccessfulJobs(jobIDs, in: e2e, timeout: 30)

        let events = try e2e.toolEvents()
        let testStartEntries = events.enumerated()
            .filter { $0.element.contains("event start phase=test") }
        let firstTestEndIndex = try XCTUnwrap(
            events.firstIndex { $0.contains("event end phase=test") },
            "At least one test end marker should be present after both jobs finish"
        )
        XCTAssertEqual(testStartEntries.count, 2)
        XCTAssertTrue(testStartEntries.allSatisfy { $0.offset < firstTestEndIndex })
        let startedResultBundles = Set(testStartEntries.compactMap { e2eLogField("result", in: $0.element) })
        XCTAssertEqual(startedResultBundles.count, 2)

        let firstArtifacts = try XCTUnwrap(e2e.status(jobIDs[0])["artifacts"] as? [String: Any])
        let secondArtifacts = try XCTUnwrap(e2e.status(jobIDs[1])["artifacts"] as? [String: Any])
        let firstXCResult = try XCTUnwrap(firstArtifacts["xcresult"] as? String)
        let secondXCResult = try XCTUnwrap(secondArtifacts["xcresult"] as? String)
        XCTAssertNotEqual(firstXCResult, secondXCResult)
        XCTAssertTrue(startedResultBundles.contains(firstXCResult))
        XCTAssertTrue(startedResultBundles.contains(secondXCResult))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(firstXCResult)/summary.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(secondXCResult)/summary.json"))
    }

    func testWorkerRefillsCapacityWhenOneOfTwoRunningJobsFinishes() throws {
        let e2e = try E2EScenario(
            scenario: .slowSuccess,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try writeProfiles([
            (name: "demo-a", simulatorID: "SIM-A"),
            (name: "demo-b", simulatorID: "SIM-B"),
            (name: "demo-c", simulatorID: "SIM-C"),
        ], in: e2e)

        let jobIDs = try submitJobIDs(["demo-a", "demo-b", "demo-c"], in: e2e)

        try waitForEventCount(in: e2e, containing: "event start phase=build", exactly: 2, timeout: 3)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try e2e.toolEvents().filter { $0.contains("event start phase=build") }.count, 2)

        try waitForSuccessfulJobs(jobIDs, in: e2e, timeout: 30)

        let events = try e2e.toolEvents()
        let buildStarts = events.enumerated().filter { $0.element.contains("event start phase=build") }
        let firstBuildEndIndex = try XCTUnwrap(events.firstIndex { $0.contains("event end phase=build") })
        let firstTestEndIndex = try XCTUnwrap(events.firstIndex { $0.contains("event end phase=test") })
        XCTAssertEqual(buildStarts.count, 3)
        XCTAssertEqual(buildStarts.filter { $0.offset < firstBuildEndIndex }.count, 2)
        let thirdBuildStart = try XCTUnwrap(buildStarts.map(\.offset).max())
        XCTAssertGreaterThan(thirdBuildStart, firstTestEndIndex)
    }

    func testWorkerSerializesConcurrentJobsOnSameSimulatorLease() throws {
        let e2e = try E2EScenario(
            scenario: .slowSuccess,
            extraEnv: ["XCSTEWARD_MAX_CONCURRENT_JOBS": "2"]
        )
        try writeProfiles([
            (name: "demo-a", simulatorID: "SIM-SHARED"),
            (name: "demo-b", simulatorID: "SIM-SHARED"),
        ], in: e2e)

        let jobIDs = try submitJobIDs(["demo-a", "demo-b"], in: e2e)
        try waitForSuccessfulJobs(jobIDs, in: e2e, timeout: 30)

        for jobID in jobIDs {
            let artifacts = try XCTUnwrap(e2e.status(jobID)["artifacts"] as? [String: Any])
            let xcresult = try XCTUnwrap(artifacts["xcresult"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(xcresult)/summary.json"))
        }
        XCTAssertTrue(try e2e.stateStore().listSimulatorLeases().isEmpty)

        let toolLog = try e2e.toolLog()
        XCTAssertEqual(toolLog.components(separatedBy: "build-for-testing").count - 1, 2)
        let events = try e2e.toolEvents()
        let buildStarts = events.enumerated().filter { $0.element.contains("event start phase=build") }
        let testStarts = events.enumerated().filter { $0.element.contains("event start phase=test") }
        let testEnds = events.enumerated().filter { $0.element.contains("event end phase=test") }
        XCTAssertEqual(buildStarts.count, 2)
        XCTAssertEqual(testStarts.count, 2)
        XCTAssertEqual(testEnds.count, 2)
        let firstTestEnd = try XCTUnwrap(testEnds.first?.offset)
        XCTAssertGreaterThan(try XCTUnwrap(testStarts.last?.offset), firstTestEnd)
        XCTAssertGreaterThan(try XCTUnwrap(buildStarts.last?.offset), firstTestEnd)
        XCTAssertFalse(toolLog.contains("already leased by another XCSteward job"))
        XCTAssertFalse(toolLog.contains("Timed out waiting for simulator SIM-SHARED lease"))
    }

    func testWorkerAppliesDynamicBackpressureWithoutInterruptingRunningJobs() throws {
        let e2e = try E2EScenario(
            scenario: .dynamicBackpressure,
            extraEnv: [
                "XCSTEWARD_MAX_CONCURRENT_JOBS": "2",
                "XCSTEWARD_SAMPLE_MEMORY_PRESSURE": "1",
            ]
        )
        try writeProfiles([
            (name: "demo-a", simulatorID: "SIM-A"),
            (name: "demo-b", simulatorID: "SIM-B"),
            (name: "demo-c", simulatorID: "SIM-C"),
        ], in: e2e)

        let jobIDs = try submitJobIDs(["demo-a", "demo-b", "demo-c"], in: e2e)

        try waitForEventCount(in: e2e, containing: "event start phase=test", exactly: 2, timeout: 8)
        try e2e.writeFakeToolMarker("constrain-host")
        let healthConstrained = try waitUntil(timeout: 5) {
            guard FileManager.default.fileExists(atPath: hostHealthPath(in: e2e).path) else {
                return false
            }
            let health = try hostHealth(in: e2e)
            return (health["effective_max_jobs"] as? Int) == 1 &&
                ((health["reasons"] as? [String])?.contains("memory_pressure=warning") == true)
        }
        XCTAssertTrue(healthConstrained)

        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try e2e.toolEvents().filter { $0.contains("event start phase=test") }.count, 2)
        XCTAssertEqual(try e2e.status(jobIDs[2])["state"] as? String, "queued")

        try e2e.writeFakeToolMarker("release-running")
        try waitForSuccessfulJobs(jobIDs, in: e2e, timeout: 20)

        let events = try e2e.toolEvents()
        let testStarts = events.enumerated().filter { $0.element.contains("event start phase=test") }
        let testEnds = events.enumerated().filter { $0.element.contains("event end phase=test") }
        XCTAssertEqual(testStarts.count, 3)
        XCTAssertEqual(testEnds.count, 3)
        let thirdStart = try XCTUnwrap(testStarts.map(\.offset).max())
        let firstEnd = try XCTUnwrap(testEnds.map(\.offset).min())
        XCTAssertGreaterThan(thirdStart, firstEnd)
    }

    func testWorkerReducesConcurrentDispatchWhenHostPressureIsConstrained() throws {
        let e2e = try E2EScenario(
            scenario: .slowSuccess,
            extraEnv: [
                "XCSTEWARD_MAX_CONCURRENT_JOBS": "2",
                "XCSTEWARD_MEMORY_PRESSURE": "critical",
            ]
        )
        try writeProfiles([
            (name: "demo-a", simulatorID: "SIM-A"),
            (name: "demo-b", simulatorID: "SIM-B"),
        ], in: e2e)

        let jobIDs = try submitJobIDs(["demo-a", "demo-b"], in: e2e)

        let firstBuildStarted = try waitUntil(timeout: 10) {
            try e2e.toolLog().components(separatedBy: "build-for-testing").count - 1 == 1
        }
        let buildLog = try e2e.toolLog()
        XCTAssertTrue(firstBuildStarted, buildLog)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try e2e.toolLog().components(separatedBy: "build-for-testing").count - 1, 1)

        let health = try hostHealth(in: e2e)
        XCTAssertEqual(health["configured_max_jobs"] as? Int, 2)
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 1)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("memory_pressure=critical") == true)

        try waitForSuccessfulJobs(jobIDs, in: e2e, timeout: 20)
    }

    func testWorkerRespectsActiveSimulatorLeaseBudget() throws {
        let e2e = try E2EScenario(
            scenario: .slowSuccess,
            extraEnv: [
                "XCSTEWARD_MAX_CONCURRENT_JOBS": "2",
                "XCSTEWARD_MAX_ACTIVE_SIMULATOR_LEASES": "1",
            ]
        )
        try writeProfiles([
            (name: "demo-a", simulatorID: "SIM-A"),
            (name: "demo-b", simulatorID: "SIM-B"),
        ], in: e2e)

        let jobIDs = try submitJobIDs(["demo-a", "demo-b"], in: e2e)

        try waitForBuildCommandCount(in: e2e, count: 1, timeout: 3)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try e2e.toolLog().components(separatedBy: "build-for-testing").count - 1, 1)

        let health = try hostHealth(in: e2e)
        XCTAssertEqual(health["configured_max_jobs"] as? Int, 2)
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 1)
        XCTAssertEqual(health["max_active_simulator_leases"] as? Int, 1)
        XCTAssertTrue((health["reasons"] as? [String])?.contains { $0.hasPrefix("active_simulator_leases=") } == true)

        try waitForSuccessfulJobs(jobIDs, in: e2e, timeout: 20)
    }

    func testWorkerRunsQueuedJobsAfterInfrastructureDrainWindowClears() throws {
        let e2e = try E2EScenario(
            scenario: .success,
            extraEnv: [
                "XCSTEWARD_MAX_CONCURRENT_JOBS": "2",
                "XCSTEWARD_INFRA_FAILURE_DRAIN_LIMIT": "1",
                "XCSTEWARD_RECENT_INFRA_FAILURE_WINDOW_SECONDS": "1",
            ]
        )
        let store = try e2e.stateStore()
        try store.recordInfrastructureEvent(
            jobID: "previous-job",
            simulatorID: "SIM-123",
            resultClass: .runnerBootstrapFailure,
            message: "previous infra failure"
        )
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let jobID = try e2e.jobID(from: e2e.submitJSON())

        let healthWritten = try waitUntil(timeout: 3) {
            FileManager.default.fileExists(atPath: hostHealthPath(in: e2e).path)
        }
        XCTAssertTrue(healthWritten)
        XCTAssertEqual(try e2e.status(jobID)["state"] as? String, "queued")

        let health = try hostHealth(in: e2e)
        XCTAssertEqual(health["effective_max_jobs"] as? Int, 0)
        XCTAssertEqual(health["draining"] as? Bool, true)
        XCTAssertTrue((health["reasons"] as? [String])?.contains("drain_recent_infrastructure_failures=1") == true)
        XCTAssertFalse(try e2e.toolLog().contains("build-for-testing"))

        let lease = try XCTUnwrap(try store.currentLease())
        XCTAssertTrue(isPIDAlive(lease.pid))

        _ = try e2e.waitForStatus(jobID, state: "succeeded", timeout: 8)
        XCTAssertTrue(try e2e.toolLog().contains("build-for-testing"))
    }

    func testSerialWorkerWaitsForTemporaryInfrastructureDrainToClear() throws {
        let e2e = try E2EScenario(
            scenario: .success,
            extraEnv: [
                "XCSTEWARD_INFRA_FAILURE_DRAIN_LIMIT": "1",
                "XCSTEWARD_RECENT_INFRA_FAILURE_WINDOW_SECONDS": "1",
            ]
        )
        let store = try e2e.stateStore()
        try store.recordInfrastructureEvent(
            jobID: "previous-job",
            simulatorID: "SIM-123",
            resultClass: .runnerBootstrapFailure,
            message: "previous infra failure"
        )
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            """
        )

        let jobID = try e2e.jobID(from: e2e.submitJSON())
        _ = try e2e.waitForStatus(jobID, state: "queued", timeout: 3)

        let lease = try XCTUnwrap(try store.currentLease())
        XCTAssertTrue(isPIDAlive(lease.pid))

        _ = try e2e.waitForStatus(jobID, state: "succeeded", timeout: 8)
        XCTAssertTrue(try e2e.toolLog().contains("build-for-testing"))
    }

    private func writeProfiles(
        _ profiles: [(name: String, simulatorID: String)],
        in e2e: E2EScenario
    ) throws {
        for profile in profiles {
            try e2e.writeProfile(
                name: profile.name,
                body: """
                project_path = "App.xcodeproj"
                scheme = "Demo"
                default_simulator_id = "\(profile.simulatorID)"
                """
            )
        }
    }

    private func submitJobIDs(_ projects: [String], in e2e: E2EScenario) throws -> [String] {
        try projects.map { project in
            try e2e.jobID(from: e2e.submitJSON(project: project))
        }
    }

    private func waitForSuccessfulJobs(
        _ jobIDs: [String],
        in e2e: E2EScenario,
        timeout: TimeInterval
    ) throws {
        let allFinished = try waitUntil(timeout: timeout) {
            for jobID in jobIDs {
                guard try e2e.status(jobID)["state"] as? String == "succeeded" else {
                    return false
                }
            }
            return true
        }
        let log = try e2e.toolLog()
        XCTAssertTrue(allFinished, log)
    }

    private func waitForEventCount(
        in e2e: E2EScenario,
        containing needle: String,
        exactly expectedCount: Int? = nil,
        atLeast minimumCount: Int? = nil,
        timeout: TimeInterval
    ) throws {
        let matched = try waitUntil(timeout: timeout) {
            let count = try e2e.toolEvents().filter { $0.contains(needle) }.count
            if let expectedCount {
                return count == expectedCount
            }
            if let minimumCount {
                return count >= minimumCount
            }
            return false
        }
        let log = try e2e.toolLog()
        XCTAssertTrue(matched, log)
    }

    private func waitForBuildCommandCount(
        in e2e: E2EScenario,
        count expectedCount: Int,
        timeout: TimeInterval
    ) throws {
        let matched = try waitUntil(timeout: timeout) {
            try e2e.toolLog().components(separatedBy: "build-for-testing").count - 1 == expectedCount
        }
        let log = try e2e.toolLog()
        XCTAssertTrue(matched, log)
    }

    private func hostHealth(in e2e: E2EScenario) throws -> [String: Any] {
        try XCTUnwrap(parseJSON(String(contentsOf: hostHealthPath(in: e2e))) as? [String: Any])
    }

    private func hostHealthPath(in e2e: E2EScenario) -> URL {
        e2e.stateRoot.appendingPathComponent("host-health.json")
    }
}
