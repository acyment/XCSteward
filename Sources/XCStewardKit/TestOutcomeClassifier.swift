import Foundation

struct TestOutcomeClassifier {
    private let resultBundleExists: (URL) -> Bool

    init(resultBundleExists: @escaping (URL) -> Bool) {
        self.resultBundleExists = resultBundleExists
    }

    func classify(run: ToolResult, resultBundle: URL) -> TestOutcome {
        if run.timedOut {
            return TestOutcome(
                resultClass: isRunnerBootstrapFailure(run: run) ? .runnerBootstrapFailure : .testTimeout,
                exitCode: run.exitCode
            )
        }
        if run.exitCode == 0 {
            return TestOutcome(
                resultClass: resultBundleExists(resultBundle) ? .success : .artifactFailure,
                exitCode: 0
            )
        }
        if isRunnerConfigurationFailure(run: run) {
            return TestOutcome(resultClass: .runnerBootstrapFailure, exitCode: run.exitCode)
        }
        if !resultBundleExists(resultBundle) {
            return TestOutcome(resultClass: .artifactFailure, exitCode: run.exitCode)
        }
        return TestOutcome(resultClass: .testFailure, exitCode: run.exitCode)
    }

    func shouldRetryBootstrapFailure(run: ToolResult) -> Bool {
        isRunnerBootstrapFailure(run: run)
    }

    private func isRunnerBootstrapFailure(run: ToolResult) -> Bool {
        output(run.output, containsAny: bootstrapFailurePatterns)
    }

    private func isRunnerConfigurationFailure(run: ToolResult) -> Bool {
        output(run.output, containsAny: configurationFailurePatterns)
    }

    private func output(_ output: String, containsAny patterns: [String]) -> Bool {
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
}
