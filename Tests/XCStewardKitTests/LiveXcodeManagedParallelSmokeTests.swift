// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import Darwin
import XCTest
@testable import XCStewardKit

final class LiveXcodeManagedParallelSmokeTests: XCTestCase {
    func testLiveXcodeManagedParallelSmoke() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE"] == "1" else {
            throw XCTSkip("Set XCSTEWARD_RUN_LIVE_XCODE_MANAGED_SMOKE=1 to run the live Xcode-managed parallel smoke test.")
        }
        guard let simulatorID = nonEmpty(environment["XCSTEWARD_LIVE_SIMULATOR_ID"]) else {
            throw XCTSkip("Set XCSTEWARD_LIVE_SIMULATOR_ID to an iOS Simulator UDID before running the live smoke test.")
        }

        let temp = try makeUntrackedTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        defer {
            cleanupLiveSmokeState(stateRoot: stateRoot)
        }

        let project = try liveProject(environment: environment)
        let maxWorkers = max(Int(environment["XCSTEWARD_LIVE_MAX_WORKERS"] ?? "") ?? 2, 1)
        let waitTimeout = nonEmpty(environment["XCSTEWARD_LIVE_WAIT_TIMEOUT"]) ?? "600"

        try writeLiveProfile(
            stateRoot: stateRoot,
            project: project,
            simulatorID: simulatorID,
            maxWorkers: maxWorkers
        )

        let result = try runCLI(
            arguments: [
                "submit",
                "--state-root", stateRoot.path,
                "--project", "live-xcode-managed",
                "--wait",
                "--wait-timeout", waitTimeout,
                "--json",
            ],
            environment: [
                "XCSTEWARD_FOREIGN_ACTIVITY_POLICY": environment["XCSTEWARD_LIVE_FOREIGN_ACTIVITY_POLICY"] ?? "ignore",
            ]
        )

        guard result.status == 0 else {
            XCTFail("stateRoot: \(stateRoot.path)\nstdout: \(result.stdout)\nstderr: \(result.stderr)")
            return
        }
        let json = try XCTUnwrap(parseJSON(result.stdout) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        let jobID = try XCTUnwrap(json["job_id"] as? String)

        let counts = try XCTUnwrap(json["counts"] as? [String: Any])
        let testsRun = try XCTUnwrap(counts["testsRun"] as? Int)
        XCTAssertGreaterThanOrEqual(testsRun, project.minimumExpectedTests)

        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let xcresult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: xcresult))

        let jobDir = stateRoot.appendingPathComponent("jobs/\(jobID)")
        let summaryURL = jobDir.appendingPathComponent("artifacts/summary.json")
        let runMetadataURL = stateRoot.appendingPathComponent("jobs/\(jobID)/artifacts/run-metadata.json")
        let runMetadata = try XCTUnwrap(parseJSON(String(contentsOf: runMetadataURL)) as? [String: Any])
        let profileMetadata = try XCTUnwrap(runMetadata["profile"] as? [String: Any])
        let parallelMetadata = try XCTUnwrap(profileMetadata["parallel"] as? [String: Any])
        XCTAssertEqual(parallelMetadata["mode"] as? String, "xcode-managed")
        XCTAssertEqual(parallelMetadata["maxWorkers"] as? Int, maxWorkers)
        XCTAssertEqual(parallelMetadata["exactWorkers"] as? Bool, true)

        let probeWarnings = runMetadata["probe_warnings"] as? [[String: Any]] ?? []
        print([
            "XCSTEWARD_LIVE_SMOKE_EVIDENCE",
            "state_root=\(stateRoot.path)",
            "job_id=\(jobID)",
            "job_dir=\(jobDir.path)",
            "summary=\(summaryURL.path)",
            "run_metadata=\(runMetadataURL.path)",
            "xcresult=\(xcresult)",
            "tests_run=\(testsRun)",
            "probe_warnings=\(probeWarnings.count)",
        ].joined(separator: " "))
    }

    private func liveProject(environment: [String: String]) throws -> LiveSmokeProject {
        if let repoRoot = nonEmpty(environment["XCSTEWARD_LIVE_REPO_ROOT"]) {
            guard let scheme = nonEmpty(environment["XCSTEWARD_LIVE_SCHEME"]) else {
                throw XCTSkip("Set XCSTEWARD_LIVE_SCHEME when XCSTEWARD_LIVE_REPO_ROOT points at an existing project.")
            }
            return LiveSmokeProject(
                repoRoot: URL(fileURLWithPath: repoRoot),
                scheme: scheme,
                projectPath: nonEmpty(environment["XCSTEWARD_LIVE_PROJECT_PATH"]),
                workspacePath: nonEmpty(environment["XCSTEWARD_LIVE_WORKSPACE_PATH"]),
                minimumExpectedTests: 1
            )
        }

        return try bundledDemoAppProject()
    }

    private func writeLiveProfile(
        stateRoot: URL,
        project: LiveSmokeProject,
        simulatorID: String,
        maxWorkers: Int
    ) throws {
        var lines = [
            "repo_root = \"\(project.repoRoot.path)\"",
            "scheme = \"\(project.scheme)\"",
            "default_simulator_id = \"\(simulatorID)\"",
        ]
        if let projectPath = project.projectPath {
            lines.append("project_path = \"\(projectPath)\"")
        }
        if let workspacePath = project.workspacePath {
            lines.append("workspace_path = \"\(workspacePath)\"")
        }
        lines.append(
            """

            [parallel]
            mode = "xcode-managed"
            max_workers = \(maxWorkers)
            exact_workers = true

            [timeouts]
            boot = 120
            build = 600
            test = 600

            [destination]
            timeout = 120
            """
        )
        try writeText(lines.joined(separator: "\n"), to: stateRoot.appendingPathComponent("projects/live-xcode-managed.toml"))
    }

    private func bundledDemoAppProject() throws -> LiveSmokeProject {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let demoRoot = repoRoot.appendingPathComponent("Examples/DemoApp")
        let projectFile = demoRoot.appendingPathComponent("DemoApp.xcodeproj/project.pbxproj")
        guard FileManager.default.fileExists(atPath: projectFile.path) else {
            throw XCTSkip("Set XCSTEWARD_LIVE_REPO_ROOT to an iOS project, or keep Examples/DemoApp available.")
        }
        return LiveSmokeProject(
            repoRoot: demoRoot,
            scheme: "DemoApp",
            projectPath: "DemoApp.xcodeproj",
            workspacePath: nil,
            minimumExpectedTests: 1
        )
    }
}

private struct LiveSmokeProject {
    var repoRoot: URL
    var scheme: String
    var projectPath: String?
    var workspacePath: String?
    var minimumExpectedTests: Int
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func cleanupLiveSmokeState(stateRoot: URL) {
    terminateRecordedLiveSmokeProcesses(stateRoot: stateRoot)
    terminateProcessesReferencing(stateRoot: stateRoot)
}

private func terminateRecordedLiveSmokeProcesses(stateRoot: URL) {
    guard let store = try? StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot))) else {
        return
    }

    var pids = Set<Int32>()
    if let jobs = try? store.listJobs() {
        for job in jobs {
            if let processID = job.processID {
                pids.insert(processID)
            }
        }
    }
    if let workerLease = try? store.currentLease() {
        pids.insert(workerLease.pid)
    }
    if let simulatorLeases = try? store.listSimulatorLeases() {
        for lease in simulatorLeases {
            pids.insert(lease.pid)
        }
    }

    for pid in pids.sorted() {
        terminateLiveSmokePID(pid)
    }
}

private func terminateProcessesReferencing(stateRoot: URL) {
    let rootPath = stateRoot.path
    for process in liveSmokeProcessListing() where process.command.contains(rootPath) {
        terminateLiveSmokePID(process.pid)
    }
}

private func liveSmokeProcessListing() -> [(pid: Int32, command: String)] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,command="]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return []
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else {
        return []
    }
    return text.split(separator: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return nil
        }
        let pidText = trimmed[..<separator]
        let command = trimmed[separator...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(pidText), !command.isEmpty else {
            return nil
        }
        return (pid: pid, command: command)
    }
}

private func terminateLiveSmokePID(_ pid: Int32) {
    guard pid > 1, pid != getpid(), isPIDAlive(pid) else {
        return
    }

    if kill(-pid, SIGTERM) != 0 {
        _ = kill(pid, SIGTERM)
    }
    if waitForLiveSmokePIDExit(pid, timeout: 2) {
        return
    }

    if kill(-pid, SIGKILL) != 0 {
        _ = kill(pid, SIGKILL)
    }
    _ = waitForLiveSmokePIDExit(pid, timeout: 2)
}

private func waitForLiveSmokePIDExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !isPIDAlive(pid) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return !isPIDAlive(pid)
}
