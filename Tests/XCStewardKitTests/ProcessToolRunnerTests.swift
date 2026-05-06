import Foundation
import XCTest
@testable import XCStewardKit

final class ProcessToolRunnerTests: XCTestCase {
    func testProcessToolRunnerCapturesLargeOutputWithoutDeadlock() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/bash
            set -euo pipefail
            for i in $(seq 1 12000); do
              printf 'line-%05d\\n' "$i"
            done
            """,
            to: bin.appendingPathComponent("large-output")
        )

        let runner = ProcessToolRunner()
        let result = try runner.run(
            tool: "large-output",
            arguments: [],
            environment: ["PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"],
            workingDirectory: nil,
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.output.contains("line-12000"))
        XCTAssertGreaterThan(result.output.count, 65_536)
    }

    func testProcessToolRunnerContinuesAfterInterruptedWaitPID() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/bash
            set -euo pipefail
            echo ok
            """,
            to: bin.appendingPathComponent("quick-success")
        )
        let waiter = ScriptedWaitPID(firstError: EINTR)
        let runner = ProcessToolRunner(waitPID: waiter.wait)

        let result = try runner.run(
            tool: "quick-success",
            arguments: [],
            environment: ["PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"],
            workingDirectory: nil,
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.output.contains("ok"))
    }

    func testProcessToolRunnerThrowsWhenWaitPIDFailsUnexpectedly() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/bash
            set -euo pipefail
            while true; do
              sleep 1
            done
            """,
            to: bin.appendingPathComponent("long-running")
        )
        let waiter = ScriptedWaitPID(firstError: ECHILD)
        let runner = ProcessToolRunner(waitPID: waiter.wait)

        XCTAssertThrowsError(
            try runner.run(
                tool: "long-running",
                arguments: [],
                environment: ["PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"],
                workingDirectory: nil,
                timeout: 5
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Unable to monitor process"))
        }
    }

    func testProcessToolRunnerForcesExitWhenTimedOutProcessIgnoresTerminate() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/bash
            set -euo pipefail
            trap '' TERM
            echo started
            while true; do
              :
            done
            """,
            to: bin.appendingPathComponent("ignore-term")
        )

        let runner = ProcessToolRunner()
        let startedAt = Date()
        let result = try runner.run(
            tool: "ignore-term",
            arguments: [],
            environment: ["PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"],
            workingDirectory: nil,
            timeout: 0.1
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 4)
    }

    func testProcessToolRunnerTimeoutTerminatesChildProcessGroup() throws {
        let temp = try makeTempDirectory()
        let bin = temp.appendingPathComponent("bin")
        let marker = temp.appendingPathComponent("child-terminated")
        let ready = temp.appendingPathComponent("child-ready")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/bash
            set -euo pipefail
            (
              child_sleep=""
              trap 'echo child-terminated > "$MARKER"; if [[ -n "$child_sleep" ]]; then kill "$child_sleep" 2>/dev/null || true; fi; exit 0' TERM
              touch "$READY"
              while true; do
                sleep 1 &
                child_sleep="$!"
                wait "$child_sleep" || true
              done
            ) &
            child="$!"
            while [[ ! -f "$READY" ]]; do
              sleep 0.01
            done
            trap '' TERM
            wait "$child"
            """,
            to: bin.appendingPathComponent("child-group")
        )

        let runner = ProcessToolRunner()
        let result = try runner.run(
            tool: "child-group",
            arguments: [],
            environment: [
                "PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")",
                "MARKER": marker.path,
                "READY": ready.path,
            ],
            workingDirectory: nil,
            timeout: 1
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }
}

private final class ScriptedWaitPID: @unchecked Sendable {
    private let lock = NSLock()
    private let firstError: Int32
    private var hasReturnedFirstError = false

    init(firstError: Int32) {
        self.firstError = firstError
    }

    func wait(pid: pid_t, status: UnsafeMutablePointer<Int32>?, options: Int32) -> pid_t {
        lock.lock()
        let shouldReturnFirstError = !hasReturnedFirstError
        if shouldReturnFirstError {
            hasReturnedFirstError = true
        }
        lock.unlock()

        if shouldReturnFirstError {
            errno = firstError
            return -1
        }
        return Darwin.waitpid(pid, status, options)
    }
}
