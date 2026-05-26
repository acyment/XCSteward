import Foundation
import XCTest
@testable import XCStewardKit

struct E2EScenario {
    let temp: URL
    let stateRoot: URL
    let repoRoot: URL
    let fakeTools: FakeToolEnvironment

    init(
        scenario: FakeScenario,
        extraEnv: [String: String] = [:],
        function: String = #function
    ) throws {
        temp = try makeTempDirectory(function: function)
        stateRoot = temp.appendingPathComponent("state")
        repoRoot = temp.appendingPathComponent("repo")
        fakeTools = try makeFakeToolEnvironment(scenario: scenario, extraEnv: extraEnv)
    }

    func writeProfile(name: String = "demo", body: String) throws {
        try createProfile(name: name, stateRoot: stateRoot, repoRoot: repoRoot, body: body)
    }

    @discardableResult
    func submit(
        project: String = "demo",
        wait: Bool = false,
        json: Bool = true,
        extraArguments: [String] = []
    ) throws -> CLIResult {
        var arguments = [
            "submit",
            "--state-root", stateRoot.path,
            "--project", project,
        ]
        arguments.append(contentsOf: extraArguments)
        if wait {
            arguments.append("--wait")
        }
        if json {
            arguments.append("--json")
        }
        return try runCLI(arguments: arguments, environment: fakeTools.env)
    }

    func submitJSON(
        project: String = "demo",
        wait: Bool = false,
        extraArguments: [String] = []
    ) throws -> [String: Any] {
        let result = try submit(project: project, wait: wait, extraArguments: extraArguments)
        return try result.jsonObject()
    }

    @discardableResult
    func cancel(_ jobID: String, json: Bool = true) throws -> CLIResult {
        var arguments = ["cancel", "--state-root", stateRoot.path, jobID]
        if json {
            arguments.append("--json")
        }
        return try runCLI(arguments: arguments, environment: fakeTools.env)
    }

    func status(_ jobID: String) throws -> [String: Any] {
        try runCLI(
            arguments: ["status", "--state-root", stateRoot.path, jobID, "--json"],
            environment: fakeTools.env
        ).jsonObject()
    }

    func artifacts(_ jobID: String) throws -> [String: Any] {
        try runCLI(
            arguments: ["artifacts", "--state-root", stateRoot.path, jobID, "--json"],
            environment: fakeTools.env
        ).jsonObject()
    }

    func logs(_ jobID: String) throws -> String {
        try runCLI(
            arguments: ["logs", "--state-root", stateRoot.path, jobID],
            environment: fakeTools.env
        ).stdout
    }

    func waitForStatus(_ jobID: String, state: String, timeout: TimeInterval = 10) throws -> [String: Any] {
        let matched = try waitUntil(timeout: timeout) {
            try status(jobID)["state"] as? String == state
        }
        XCTAssertTrue(matched)
        return try status(jobID)
    }

    func waitForTerminal(_ jobID: String, timeout: TimeInterval = 10) throws -> [String: Any] {
        let matched = try waitUntil(timeout: timeout) {
            try (status(jobID)["state"] as? String)?.e2eIsTerminalJobState == true
        }
        let log = try toolLog()
        XCTAssertTrue(matched, log)
        return try status(jobID)
    }

    func waitForToolEvents(
        matching predicate: @escaping (Substring) -> Bool,
        count expectedCount: Int,
        timeout: TimeInterval = 10
    ) throws {
        let matched = try waitUntil(timeout: timeout) {
            try toolEvents().filter(predicate).count == expectedCount
        }
        let log = try toolLog()
        XCTAssertTrue(matched, log)
    }

    func jobID(from json: [String: Any]) throws -> String {
        try XCTUnwrap(json["job_id"] as? String)
    }

    func jobDir(_ jobID: String) -> URL {
        stateRoot.appendingPathComponent("jobs/\(jobID)")
    }

    func toolLog() throws -> String {
        guard FileManager.default.fileExists(atPath: fakeTools.log.path) else {
            return ""
        }
        return try String(contentsOf: fakeTools.log)
    }

    func toolEvents() throws -> [Substring] {
        try toolLog()
            .split(separator: "\n")
            .filter { $0.hasPrefix("event ") }
    }

    func xcodebuildLine(containing needle: String) throws -> Substring {
        try XCTUnwrap(toolLog().split(separator: "\n").first { $0.contains(needle) })
    }

    func xcodebuildLines(containing needle: String) throws -> [Substring] {
        try toolLog().split(separator: "\n").filter { $0.contains(needle) }
    }

    func manualRunDiagnostics(from artifacts: [String: Any]) throws -> (summary: [String: Any], shards: [[String: Any]]) {
        let diagnosticsPath = try XCTUnwrap(artifacts["diagnostics"] as? String)
        let summary = try XCTUnwrap(parseJSON(String(contentsOfFile: diagnosticsPath)) as? [String: Any])
        let shards = try XCTUnwrap(summary["shards"] as? [[String: Any]])
        return (summary, shards)
    }

    func stateStore() throws -> StateStore {
        try StateStore(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))
    }

    func writeFakeToolMarker(_ name: String) throws {
        try writeText("", to: fakeTools.root.appendingPathComponent(name))
    }
}

extension CLIResult {
    func jsonObject(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(parseJSON(stdout) as? [String: Any], file: file, line: line)
    }
}

func e2eLogField(_ field: String, in line: Substring) -> String? {
    let prefix = "\(field)="
    return line.split(separator: " ")
        .first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count)) }
}

extension String {
    var e2eIsTerminalJobState: Bool {
        ["succeeded", "failed", "canceled", "interrupted"].contains(self)
    }
}
