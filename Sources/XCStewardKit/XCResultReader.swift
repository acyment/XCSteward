import Foundation

struct XCResultReader {
    private let environment: AppEnvironment
    private let parser = XCResultParser()
    private let warningSink: (@Sendable (ProbeWarning) -> Void)?

    init(environment: AppEnvironment, warningSink: (@Sendable (ProbeWarning) -> Void)? = nil) {
        self.environment = environment
        self.warningSink = warningSink
    }

    func summary(at resultBundle: URL) -> XCResultSummary? {
        guard environment.fileSystem.fileExists(resultBundle) else {
            return nil
        }
        let command = ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", resultBundle.path]
        let tool: ToolResult
        do {
            tool = try environment.toolRunner.run(
                tool: "xcrun",
                arguments: Array(command.dropFirst()),
                environment: [:],
                workingDirectory: nil,
                timeout: 30
            )
        } catch {
            recordWarning(
                source: "xcresulttool.summary",
                command: command,
                message: "xcresulttool summary probe could not run: \(error)"
            )
            return nil
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
            return nil
        }
        guard let summary = parser.summary(from: data) else {
            recordWarning(
                source: "xcresulttool.summary",
                command: command,
                message: "xcresulttool summary probe produced unparseable output",
                result: tool
            )
            return nil
        }
        return summary
    }

    func testTimings(at resultBundle: URL) -> [TestTimingSample] {
        guard environment.fileSystem.fileExists(resultBundle) else {
            return []
        }
        let command = ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", resultBundle.path]
        let tool: ToolResult
        do {
            tool = try environment.toolRunner.run(
                tool: "xcrun",
                arguments: Array(command.dropFirst()),
                environment: [:],
                workingDirectory: nil,
                timeout: 30
            )
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
            if value is Bool {
                return nil
            }
            if let number = value as? NSNumber {
                return number.doubleValue
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
