// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct TestOutcomeClassifier {
    private let resultBundleExists: (URL) -> Bool

    init(resultBundleExists: @escaping (URL) -> Bool) {
        self.resultBundleExists = resultBundleExists
    }

    func classify(run: ToolResult, resultBundle: URL) -> TestOutcome {
        if run.timedOut {
            return TestOutcome(
                resultClass: isPreTestRunnerBootstrapFailure(run: run) ? .runnerBootstrapFailure : .testTimeout,
                exitCode: run.exitCode
            )
        }
        if run.exitCode == 0 {
            return TestOutcome(
                resultClass: resultBundleExists(resultBundle) ? .success : .artifactFailure,
                exitCode: 0
            )
        }
        if isPreTestRunnerConfigurationFailure(run: run) {
            return TestOutcome(resultClass: .runnerBootstrapFailure, exitCode: run.exitCode)
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

    private func testExecutionStarted(_ output: String) -> Bool {
        outputContainsAny(output, patterns: testStartPatterns)
    }

    private func outputContainsAny(_ output: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            output.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private var bootstrapFailurePatterns: [String] {
        [
            "Failed to background test runner",
            "operation never finished bootstrapping",
            "Lost connection to testmanagerd",
            "Early unexpected exit",
        ]
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
            "Testing started",
            "Test Suite '",
            "Test Case '-[",
        ]
    }
}
