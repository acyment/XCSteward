// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct TestOutcomeClassifier {
    private let resultBundleExists: (URL) -> Bool

    init(resultBundleExists: @escaping (URL) -> Bool) {
        self.resultBundleExists = resultBundleExists
    }

    func classify(run: ToolResult, resultBundle: URL, simulatorID: String? = nil) -> TestOutcome {
        if run.timedOut {
            let isPreXCTestTimeout = !timeoutHasXCTestExecutionEvidence(run.output)
            let isBootstrapFailure = isPreXCTestTimeout || isPreTestRunnerBootstrapFailure(run: run)
            return TestOutcome(
                resultClass: isBootstrapFailure ? .runnerBootstrapFailure : .testTimeout,
                exitCode: run.exitCode,
                summaryLine: isPreXCTestTimeout
                    ? preXCTestTimeoutSummary(simulatorID: simulatorID)
                    : (isBootstrapFailure ? preTestBootstrapSummary(run: run, simulatorID: simulatorID) : nil),
                diagnosticExcerpt: isPreXCTestTimeout
                    ? JobDiagnosticExcerpt(
                        subtype: "pre_xctest_timeout",
                        phase: "test",
                        evidencePaths: [],
                        excerpt: diagnosticExcerpt(from: run.output)
                    )
                    : nil
            )
        }
        if run.exitCode == 0 {
            return TestOutcome(
                resultClass: resultBundleExists(resultBundle) ? .success : .artifactFailure,
                exitCode: 0
            )
        }
        if isPreTestRunnerConfigurationFailure(run: run) {
            return TestOutcome(
                resultClass: .runnerBootstrapFailure,
                exitCode: run.exitCode,
                summaryLine: preTestBootstrapSummary(run: run, simulatorID: simulatorID)
            )
        }
        if !resultBundleExists(resultBundle) {
            return TestOutcome(resultClass: .artifactFailure, exitCode: run.exitCode)
        }
        return TestOutcome(resultClass: .testFailure, exitCode: run.exitCode)
    }

    func shouldRetryBootstrapFailure(run: ToolResult) -> Bool {
        isPreTestRunnerBootstrapFailure(run: run)
    }

    private func isPreTestRunnerBootstrapFailure(run: ToolResult) -> Bool {
        !testExecutionStarted(run.output) && outputContainsAny(run.output, patterns: bootstrapFailurePatterns)
    }

    private func isPreTestRunnerConfigurationFailure(run: ToolResult) -> Bool {
        !testExecutionStarted(run.output) && outputContainsAny(run.output, patterns: configurationFailurePatterns)
    }

    private func preTestBootstrapSummary(run: ToolResult, simulatorID: String?) -> String? {
        SimulatorBootstrapFailureDiagnosis.summaryLine(
            errorDescription: run.output,
            simulatorID: simulatorID
        )
    }

    private func testExecutionStarted(_ output: String) -> Bool {
        outputContainsAny(output, patterns: testStartPatterns)
    }

    private func timeoutHasXCTestExecutionEvidence(_ output: String) -> Bool {
        outputContainsAny(output, patterns: timeoutXCTestEvidencePatterns)
    }

    private func preXCTestTimeoutSummary(simulatorID: String?) -> String {
        SimulatorBootstrapFailureDiagnosis.preXCTestTimeoutSummaryLine(
            timeoutSeconds: nil,
            simulatorID: simulatorID
        )
    }

    private func diagnosticExcerpt(from output: String) -> String {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let excerpt = lines.suffix(40).joined(separator: "\n")
        if excerpt.isEmpty {
            return "No XCTest output was observed before the test command timed out."
        }
        guard excerpt.count > 4_000 else {
            return excerpt
        }
        let start = excerpt.index(excerpt.endIndex, offsetBy: -4_000)
        return "[excerpt truncated]\n\(excerpt[start...])"
    }

    private func outputContainsAny(_ output: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            output.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private var bootstrapFailurePatterns: [String] {
        SimulatorBootstrapFailureDiagnosis.bootstrapFailurePatterns
    }

    private var configurationFailurePatterns: [String] {
        bootstrapFailurePatterns + [
            "There are no test bundles available to test.",
            "does not have an associated test plan named",
            "Unable to find a device matching the provided destination specifier",
            "No .xctestrun file was generated under",
        ]
    }

    private var testStartPatterns: [String] {
        [
            "Test Suite '",
            "Test Case '-[",
        ]
    }

    private var timeoutXCTestEvidencePatterns: [String] {
        testStartPatterns + [
            "Testing started",
        ]
    }
}
