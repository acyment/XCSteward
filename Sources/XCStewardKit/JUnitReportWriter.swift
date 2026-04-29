import Foundation

struct JUnitReportWriter: Sendable {
    private let resultPolicy = ResultClassPolicy()

    func xml(
        project: String,
        resultClass: ResultClass,
        counts: JobCounts?,
        durationSeconds: Double,
        cases: [JUnitTestCase]
    ) -> String {
        let tests = counts?.testsRun ?? cases.count
        let failures = counts?.testsFailed ?? cases.filter { $0.failureMessage != nil }.count
        let skipped = counts?.testsSkipped ?? cases.filter(\.skipped).count
        let errors = cases.filter { $0.errorMessage != nil }.count
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="\(xmlEscape(project))" tests="\(tests)" failures="\(failures)" errors="\(errors)" skipped="\(skipped)" time="\(formatTime(durationSeconds))" result="\(xmlEscape(resultClass.rawValue))">

        """
        for testCase in cases {
            xml += testcaseXML(for: testCase)
        }
        xml += "</testsuite>\n"
        return xml
    }

    func casesForSingleRun(
        resultClass: ResultClass,
        counts: JobCounts?,
        onlyTesting: [String]
    ) -> [JUnitTestCase] {
        if let errorMessage = runErrorMessage(for: resultClass), counts == nil {
            return [
                JUnitTestCase(
                    className: "XCSteward",
                    name: resultClass.rawValue,
                    timeSeconds: 0,
                    failureMessage: nil,
                    errorMessage: errorMessage,
                    skipped: false
                ),
            ]
        }
        return casesForIdentifiers(
            onlyTesting.isEmpty ? placeholderIdentifiers(counts: counts, fallbackName: "xcresult-summary") : onlyTesting,
            counts: counts,
            resultClass: resultClass,
            fallbackName: "xcresult-summary"
        )
    }

    func casesForShardReports(_ reports: [ShardReport]) -> [JUnitTestCase] {
        reports.flatMap { report -> [JUnitTestCase] in
            if let errorMessage = runErrorMessage(for: report.resultClass), report.counts == nil {
                return [
                    JUnitTestCase(
                        className: "XCSteward.\(report.shardID)",
                        name: report.resultClass.rawValue,
                        timeSeconds: 0,
                        failureMessage: nil,
                        errorMessage: errorMessage,
                        skipped: false
                    ),
                ]
            }
            let identifiers = report.onlyTesting.isEmpty
                ? placeholderIdentifiers(counts: report.counts, fallbackName: report.shardID)
                : report.onlyTesting
            return casesForIdentifiers(
                identifiers,
                counts: report.counts,
                resultClass: report.resultClass,
                fallbackName: report.shardID
            )
        }
    }

    private func testcaseXML(for testCase: JUnitTestCase) -> String {
        let attributes = "classname=\"\(xmlEscape(testCase.className))\" name=\"\(xmlEscape(testCase.name))\" time=\"\(formatTime(testCase.timeSeconds))\""
        if let failureMessage = testCase.failureMessage {
            return """
              <testcase \(attributes)>
                <failure message="\(xmlEscape(failureMessage))">\(xmlEscape(failureMessage))</failure>
              </testcase>

            """
        }
        if let errorMessage = testCase.errorMessage {
            return """
              <testcase \(attributes)>
                <error message="\(xmlEscape(errorMessage))">\(xmlEscape(errorMessage))</error>
              </testcase>

            """
        }
        if testCase.skipped {
            return """
              <testcase \(attributes)>
                <skipped />
              </testcase>

            """
        }
        return "  <testcase \(attributes) />\n"
    }

    private func casesForIdentifiers(
        _ identifiers: [String],
        counts: JobCounts?,
        resultClass: ResultClass,
        fallbackName: String
    ) -> [JUnitTestCase] {
        let identifiers = identifiers.isEmpty
            ? placeholderIdentifiers(counts: counts, fallbackName: fallbackName)
            : identifiers
        let failedCount = resultClass == .testFailure ? min(counts?.testsFailed ?? 0, identifiers.count) : 0
        let skippedCount = min(counts?.testsSkipped ?? 0, max(identifiers.count - failedCount, 0))
        let errorMessage = resultClass == .testTimeout ? runErrorMessage(for: resultClass) : nil

        return identifiers.enumerated().map { index, identifier in
            let identity = junitIdentity(from: identifier, fallbackName: fallbackName)
            let isFailed = index < failedCount
            let isSkipped = !isFailed && index < failedCount + skippedCount
            let isTimedOut = index == 0 && errorMessage != nil
            return JUnitTestCase(
                className: identity.className,
                name: identity.name,
                timeSeconds: 0,
                failureMessage: isFailed ? "Test failed" : nil,
                errorMessage: isTimedOut ? errorMessage : nil,
                skipped: isSkipped
            )
        }
    }

    private func placeholderIdentifiers(counts: JobCounts?, fallbackName: String) -> [String] {
        let count = max(counts?.testsRun ?? 0, 0)
        guard count > 0 else {
            return []
        }
        return (1...count).map { "\(fallbackName)/test-\(String(format: "%03d", $0))" }
    }

    private func junitIdentity(from identifier: String, fallbackName: String) -> (className: String, name: String) {
        let parts = identifier
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let name = parts.last else {
            return ("XCSteward", fallbackName)
        }
        let className = parts.dropLast().isEmpty
            ? "XCSteward"
            : parts.dropLast().joined(separator: ".")
        return (className, name)
    }

    private func runErrorMessage(for resultClass: ResultClass) -> String? {
        resultPolicy.junitErrorMessage(for: resultClass)
    }

    private func formatTime(_ seconds: Double) -> String {
        String(format: "%.3f", max(0, seconds))
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
