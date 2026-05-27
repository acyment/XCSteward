// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

enum XCResultSummaryProbeResult {
    case parsed(XCResultSummary)
    case missingBundle
    case temporarilyUnavailable
    case invalid

    var summary: XCResultSummary? {
        if case .parsed(let summary) = self {
            return summary
        }
        return nil
    }

    var failsSuccessfulTestRun: Bool {
        switch self {
        case .parsed, .temporarilyUnavailable:
            return false
        case .missingBundle, .invalid:
            return true
        }
    }
}

struct XCResultReader {
    private let environment: AppEnvironment
    private let parser = XCResultParser()
    private let warningSink: (@Sendable (ProbeWarning) -> Void)?

    init(environment: AppEnvironment, warningSink: (@Sendable (ProbeWarning) -> Void)? = nil) {
        self.environment = environment
        self.warningSink = warningSink
    }

    func summary(at resultBundle: URL, context: ToolExecutionContext? = nil) -> XCResultSummary? {
        summaryProbe(at: resultBundle, context: context).summary
    }

    func summaryProbe(at resultBundle: URL, context: ToolExecutionContext? = nil) -> XCResultSummaryProbeResult {
        guard environment.fileSystem.fileExists(resultBundle) else {
            return .missingBundle
        }
        let command = ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", resultBundle.path]
        let timeout = summaryProbeTimeout(context: context)
        for attempt in 1...2 {
            let tool: ToolResult
            do {
                tool = try runProbe(command: command, timeout: timeout, context: context)
            } catch {
                recordWarning(
                    source: "xcresulttool.summary",
                    command: command,
                    message: "xcresulttool summary probe could not run: \(error)"
                )
                return .temporarilyUnavailable
            }
            guard tool.exitCode == 0, !tool.timedOut, let data = tool.output.data(using: .utf8) else {
                recordWarning(
                    source: "xcresulttool.summary",
                    command: command,
                    message: tool.timedOut
                        ? "xcresulttool summary probe timed out"
                        : "xcresulttool summary probe failed with exit code \(tool.exitCode)",
                    result: tool
                )
                if tool.timedOut, attempt == 1 {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                return tool.timedOut ? .temporarilyUnavailable : .invalid
            }
            guard let summary = parser.summary(from: data) else {
                recordWarning(
                    source: "xcresulttool.summary",
                    command: command,
                    message: "xcresulttool summary probe produced unparseable output",
                    result: tool
                )
                return .invalid
            }
            return .parsed(summary)
        }
        return .temporarilyUnavailable
    }

    func testTimings(at resultBundle: URL, context: ToolExecutionContext? = nil) -> [TestTimingSample] {
        guard environment.fileSystem.fileExists(resultBundle) else {
            return []
        }
        let command = ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", resultBundle.path]
        let timeout = summaryProbeTimeout(context: context)
        let tool: ToolResult
        do {
            tool = try runProbe(command: command, timeout: timeout, context: context)
        } catch {
            recordWarning(
                source: "xcresulttool.tests",
                command: command,
                message: "xcresulttool test timings probe could not run: \(error)"
            )
            return []
        }
        guard tool.exitCode == 0, !tool.timedOut, let data = tool.output.data(using: .utf8) else {
            recordWarning(
                source: "xcresulttool.tests",
                command: command,
                message: tool.timedOut
                    ? "xcresulttool test timings probe timed out"
                    : "xcresulttool test timings probe failed with exit code \(tool.exitCode)",
                result: tool
            )
            return []
        }
        do {
            return try parser.testTimingSamples(from: data)
        } catch {
            recordWarning(
                source: "xcresulttool.tests",
                command: command,
                message: "xcresulttool test timings probe produced unparseable output",
                result: tool
            )
            return []
        }
    }

    private func summaryProbeTimeout(context: ToolExecutionContext?) -> TimeInterval {
        if let configured = configuredProbeTimeout() {
            return configured
        }
        guard let context else {
            return 60
        }
        return min(context.profile.timeouts.test, max(60, context.profile.timeouts.test * 0.25))
    }

    private func configuredProbeTimeout() -> TimeInterval? {
        guard let raw = environment.processInfo.environment["XCSTEWARD_XCRESULT_PROBE_TIMEOUT_SECONDS"],
              let value = TimeInterval(raw),
              value > 0 else {
            return nil
        }
        return value
    }

    private func runProbe(command: [String], timeout: TimeInterval, context: ToolExecutionContext?) throws -> ToolResult {
        guard let tool = command.first else {
            throw XCStewardError.commandFailed("Unable to run empty xcresult probe command")
        }
        let arguments = Array(command.dropFirst())
        guard let context else {
            return try environment.toolRunner.run(
                tool: tool,
                arguments: arguments,
                environment: [:],
                workingDirectory: nil,
                timeout: timeout
            )
        }

        var activePID: Int32?
        defer {
            if let activePID {
                try? context.store.clearJobProcessID(id: context.jobID, processID: activePID)
            } else {
                try? context.store.clearJobProcessID(id: context.jobID)
            }
        }

        do {
            let result = try environment.toolRunner.run(
                tool: tool,
                arguments: arguments,
                environment: [:],
                workingDirectory: nil,
                timeout: timeout,
                processStarted: { pid in
                    activePID = pid
                    try context.store.updateJob(
                        id: context.jobID,
                        patch: JobStatePatch(state: .running, processID: pid)
                    )
                },
                shouldTerminate: {
                    try context.store.fetchJob(id: context.jobID)?.cancelRequested == true
                }
            )
            recordCommand(command: command, timeout: timeout, context: context, result: result, error: nil)
            return result
        } catch {
            recordCommand(command: command, timeout: timeout, context: context, result: nil, error: error)
            throw error
        }
    }

    private func recordCommand(
        command: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        result: ToolResult?,
        error: Error?
    ) {
        guard let commandLog = context.commandLog,
              let tool = command.first else {
            return
        }
        let record = RunCommandRecord(
            tool: tool,
            arguments: Array(command.dropFirst()),
            commandLine: command.joined(separator: " "),
            workingDirectory: nil,
            timeoutSeconds: timeout,
            phase: "artifact",
            exitCode: result?.exitCode,
            timedOut: result?.timedOut ?? false,
            error: error.map { String(describing: $0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(record) else {
            return
        }
        data.append(contentsOf: "\n".utf8)
        try? environment.fileSystem.appendData(data, to: commandLog)
    }

    private func recordWarning(
        source: String,
        command: [String],
        message: String,
        result: ToolResult? = nil
    ) {
        warningSink?(ProbeWarning(
            source: source,
            command: command.joined(separator: " "),
            message: message,
            exitCode: result?.exitCode,
            timedOut: result?.timedOut,
            outputExcerpt: result.flatMap { outputExcerpt($0.output) }
        ))
    }

    private func outputExcerpt(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count <= 500 {
            return trimmed
        }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 500)
        return String(trimmed[..<end])
    }
}

struct XCResultParser: Sendable {
    func summary(from data: Data) -> XCResultSummary? {
        if let summary = try? decodeJSON(XCResultSummary.self, from: data) {
            return summary
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return summary(in: json)
    }

    func testTimingSamples(from data: Data) throws -> [TestTimingSample] {
        let json = try JSONSerialization.jsonObject(with: data)
        var samplesByIdentifier: [String: Double] = [:]

        func stringValue(_ value: Any?) -> String? {
            (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func numericValue(_ value: Any?) -> Double? {
            if let number = value as? NSNumber {
                guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
                    return nil
                }
                return number.doubleValue
            }
            if value is Bool {
                return nil
            }
            if let string = value as? String {
                return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }

        func durationValue(forKey key: String, value: Any?) -> Double? {
            let compactKey = key.filter { $0.isLetter || $0.isNumber }
            let isDurationKey = compactKey.contains("duration") || key == "time" || compactKey == "timeseconds"
            guard isDurationKey, let numeric = numericValue(value), numeric > 0 else {
                return nil
            }
            if compactKey.contains("millisecond") || compactKey.hasSuffix("ms") {
                return numeric / 1000
            }
            return numeric
        }

        func walk(_ value: Any) {
            if let array = value as? [Any] {
                array.forEach(walk)
                return
            }
            guard let object = value as? [String: Any] else {
                return
            }

            var identifier: String?
            var duration: Double?
            for (key, child) in object {
                let normalizedKey = key.lowercased()
                if identifier == nil,
                   (normalizedKey.contains("identifier") || normalizedKey == "name"),
                   let candidate = stringValue(child),
                   candidate.contains("/") {
                    identifier = candidate
                }
                if duration == nil,
                   let candidate = durationValue(forKey: normalizedKey, value: child) {
                    duration = candidate
                }
            }
            if let identifier, let duration {
                samplesByIdentifier[identifier] = duration
            }
            object.values.forEach(walk)
        }

        walk(json)
        return samplesByIdentifier
            .map { TestTimingSample(identifier: $0.key, durationSeconds: $0.value) }
            .sorted { $0.identifier < $1.identifier }
    }

    private func summary(in value: Any) -> XCResultSummary? {
        if let object = value as? [String: Any] {
            if let summary = summary(from: object) {
                return summary
            }
            for key in ["summary", "metrics", "testSummary", "testResults"] {
                if let child = object[key], let summary = summary(in: child) {
                    return summary
                }
            }
            for child in object.values {
                if let summary = summary(in: child) {
                    return summary
                }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let summary = summary(in: child) {
                    return summary
                }
            }
        }
        return nil
    }

    private func summary(from object: [String: Any]) -> XCResultSummary? {
        if let testsCount = integerValue(object["testsCount"]) {
            return XCResultSummary(
                testsCount: testsCount,
                testsFailedCount: integerValue(object["testsFailedCount"]) ?? 0,
                testsSkippedCount: integerValue(object["testsSkippedCount"]) ?? 0
            )
        }

        if let totalTestCount = integerValue(object["totalTestCount"]) {
            return XCResultSummary(
                testsCount: totalTestCount,
                testsFailedCount: integerValue(object["failedTests"]) ?? 0,
                testsSkippedCount: integerValue(object["skippedTests"]) ?? 0
            )
        }
        return nil
    }

    private func integerValue(_ value: Any?) -> Int? {
        if value is Bool {
            return nil
        }
        if let number = value as? NSNumber {
            let parsed = number.intValue
            return parsed >= 0 ? parsed : nil
        }
        if let string = value as? String {
            guard let parsed = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)),
                  parsed >= 0 else {
                return nil
            }
            return parsed
        }
        return nil
    }
}
