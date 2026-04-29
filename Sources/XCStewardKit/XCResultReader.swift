import Foundation

struct XCResultReader {
    private let environment: AppEnvironment
    private let parser = XCResultParser()

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func summary(at resultBundle: URL) -> XCResultSummary? {
        guard environment.fileSystem.fileExists(resultBundle) else {
            return nil
        }
        guard let tool = try? environment.toolRunner.run(
            tool: "xcrun",
            arguments: ["xcresulttool", "get", "test-results", "summary", "--path", resultBundle.path],
            environment: [:],
            workingDirectory: nil,
            timeout: 30
        ) else {
            return nil
        }
        guard tool.exitCode == 0, let data = tool.output.data(using: .utf8) else {
            return nil
        }
        return parser.summary(from: data)
    }

    func testTimings(at resultBundle: URL) -> [TestTimingSample] {
        guard environment.fileSystem.fileExists(resultBundle) else {
            return []
        }
        guard let tool = try? environment.toolRunner.run(
            tool: "xcrun",
            arguments: ["xcresulttool", "get", "test-results", "tests", "--path", resultBundle.path],
            environment: [:],
            workingDirectory: nil,
            timeout: 30
        ) else {
            return []
        }
        guard tool.exitCode == 0, let data = tool.output.data(using: .utf8) else {
            return []
        }
        return (try? parser.testTimingSamples(from: data)) ?? []
    }
}

struct XCResultParser: Sendable {
    func summary(from data: Data) -> XCResultSummary? {
        try? decodeJSON(XCResultSummary.self, from: data)
    }

    func testTimingSamples(from data: Data) throws -> [TestTimingSample] {
        let json = try JSONSerialization.jsonObject(with: data)
        var samplesByIdentifier: [String: Double] = [:]

        func stringValue(_ value: Any?) -> String? {
            (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func doubleValue(_ value: Any?) -> Double? {
            if let number = value as? NSNumber {
                return number.doubleValue
            }
            if let string = value as? String {
                return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
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
                   (normalizedKey.contains("duration") || normalizedKey == "time" || normalizedKey == "time_seconds"),
                   let candidate = doubleValue(child),
                   candidate > 0 {
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
}
