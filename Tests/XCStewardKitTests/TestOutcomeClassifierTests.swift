// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest
@testable import XCStewardKit

final class TestOutcomeClassifierTests: XCTestCase {
    func testSuccessfulRunRequiresResultBundle() {
        let resultBundle = URL(fileURLWithPath: "/tmp/result.xcresult")

        XCTAssertEqual(
            classifier(bundleExists: true).classify(run: toolResult(exitCode: 0), resultBundle: resultBundle).resultClass,
            .success
        )
        XCTAssertEqual(
            classifier(bundleExists: false).classify(run: toolResult(exitCode: 0), resultBundle: resultBundle).resultClass,
            .artifactFailure
        )
    }

    func testTimeoutCanBeBootstrapFailureOrTestTimeout() {
        let resultBundle = URL(fileURLWithPath: "/tmp/result.xcresult")

        XCTAssertEqual(
            classifier(bundleExists: false)
                .classify(run: toolResult(output: "xcodebuild test-without-building started", timedOut: true), resultBundle: resultBundle)
                .resultClass,
            .runnerBootstrapFailure
        )
        let preXCTest = classifier(bundleExists: false)
            .classify(run: toolResult(output: "xcodebuild test-without-building started", timedOut: true), resultBundle: resultBundle)
        XCTAssertEqual(preXCTest.summaryLine, "XCTest did not attach before the test command timed out; this is an environment/bootstrap failure, not a test case timeout. Remediation: try shutting down or erasing the selected simulator and retry once; if it repeats, run `xcsteward doctor --json` and inspect CoreSimulator diagnostics.")
        XCTAssertEqual(preXCTest.diagnosticExcerpt?.subtype, "pre_xctest_timeout")

        XCTAssertEqual(
            classifier(bundleExists: true)
                .classify(run: toolResult(output: "Testing started\nhang", timedOut: true), resultBundle: resultBundle)
                .resultClass,
            .testTimeout
        )
    }

    func testTimeoutAfterXCTestSuiteStartsIsNotRunnerBootstrapFailure() {
        let resultBundle = URL(fileURLWithPath: "/tmp/result.xcresult")

        let outcome = classifier(bundleExists: true).classify(
            run: toolResult(
                output: """
                Test Suite 'DemoTests.xctest' started at 2026-06-09.
                Lost connection to testmanagerd
                """,
                timedOut: true
            ),
            resultBundle: resultBundle
        )

        XCTAssertEqual(outcome.resultClass, .testTimeout)
    }

    func testTestingStartedWithoutXCTestSuiteCanStillBeBootstrapFailure() {
        let resultBundle = URL(fileURLWithPath: "/tmp/result.xcresult")

        let outcome = classifier(bundleExists: true).classify(
            run: toolResult(
                exitCode: 65,
                output: """
                Testing started
                Lost connection to testmanagerd
                """
            ),
            resultBundle: resultBundle,
            simulatorID: "SIM-123"
        )

        XCTAssertEqual(outcome.resultClass, .runnerBootstrapFailure)
        XCTAssertTrue(outcome.summaryLine?.contains("before XCTest attached") == true)
        XCTAssertTrue(outcome.summaryLine?.contains("environment failure") == true)
        XCTAssertTrue(outcome.summaryLine?.contains("SIM-123") == true)
    }

    func testLaunchdSimCoreSimulatorBootFailureBeforeXCTestIsBootstrapFailure() {
        let outcome = classifier(bundleExists: true).classify(
            run: toolResult(
                exitCode: 65,
                output: """
                Testing started
                An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=60):
                Unable to boot the Simulator.
                launchd failed to respond.
                Underlying error (domain=com.apple.SimLaunchHostService.RequestError, code=4):
                    Failed to start launchd_sim: could not bind to session, launchd_sim may have crashed or quit responding
                """
            ),
            resultBundle: URL(fileURLWithPath: "/tmp/result.xcresult"),
            simulatorID: "SIM-123"
        )

        XCTAssertEqual(outcome.resultClass, .runnerBootstrapFailure)
        XCTAssertEqual(outcome.exitCode, 65)
        XCTAssertTrue(outcome.summaryLine?.contains("before XCTest attached") == true)
        XCTAssertTrue(outcome.summaryLine?.contains("launchd_sim") == true)
        XCTAssertTrue(outcome.summaryLine?.contains("xcrun simctl erase SIM-123") == true)
    }

    func testConfigurationFailuresAreRunnerBootstrapFailures() {
        let outcome = classifier(bundleExists: true).classify(
            run: toolResult(
                exitCode: 65,
                output: "There are no test bundles available to test."
            ),
            resultBundle: URL(fileURLWithPath: "/tmp/result.xcresult")
        )

        XCTAssertEqual(outcome.resultClass, .runnerBootstrapFailure)
        XCTAssertEqual(outcome.exitCode, 65)
    }

    func testConfigurationFailureMatchingIgnoresCase() {
        let outcome = classifier(bundleExists: true).classify(
            run: toolResult(
                exitCode: 70,
                output: "unable to find a DEVICE matching the provided destination specifier"
            ),
            resultBundle: URL(fileURLWithPath: "/tmp/result.xcresult")
        )

        XCTAssertEqual(outcome.resultClass, .runnerBootstrapFailure)
        XCTAssertEqual(outcome.exitCode, 70)
    }

    func testConfigurationPhraseAfterTestingStartedIsTestFailureWhenBundleExists() {
        let outcome = classifier(bundleExists: true).classify(
            run: toolResult(
                exitCode: 65,
                output: """
                Test Suite 'DemoTests.xctest' started at 2026-05-23.
                Assertion failed: Unable to find a device matching the provided destination specifier
                """
            ),
            resultBundle: URL(fileURLWithPath: "/tmp/result.xcresult")
        )

        XCTAssertEqual(outcome.resultClass, .testFailure)
        XCTAssertEqual(outcome.exitCode, 65)
    }

    func testNonzeroRunWithoutResultBundleIsArtifactFailure() {
        let outcome = classifier(bundleExists: false).classify(
            run: toolResult(exitCode: 65, output: "xcodebuild failed"),
            resultBundle: URL(fileURLWithPath: "/tmp/result.xcresult")
        )

        XCTAssertEqual(outcome.resultClass, .artifactFailure)
    }

    func testNonzeroRunWithResultBundleIsTestFailure() {
        let outcome = classifier(bundleExists: true).classify(
            run: toolResult(exitCode: 65, output: "Failing test assertion"),
            resultBundle: URL(fileURLWithPath: "/tmp/result.xcresult")
        )

        XCTAssertEqual(outcome.resultClass, .testFailure)
    }

    func testBootstrapRetryOnlyMatchesBootstrapPatterns() {
        let classifier = classifier(bundleExists: false)

        XCTAssertTrue(classifier.shouldRetryBootstrapFailure(run: toolResult(output: "Lost connection to testmanagerd")))
        XCTAssertTrue(classifier.shouldRetryBootstrapFailure(run: toolResult(output: "lost connection to TestManagerD")))
        XCTAssertTrue(classifier.shouldRetryBootstrapFailure(run: toolResult(output: "Failed to start launchd_sim")))
        XCTAssertFalse(classifier.shouldRetryBootstrapFailure(run: toolResult(output: """
        Test Case '-[DemoTests testLogsBootstrapText]' started.
        Lost connection to testmanagerd
        """)))
        XCTAssertFalse(classifier.shouldRetryBootstrapFailure(run: toolResult(output: "There are no test bundles available to test.")))
        XCTAssertFalse(classifier.shouldRetryBootstrapFailure(run: toolResult(output: "Failing test assertion")))
    }
}

private func classifier(bundleExists: Bool) -> TestOutcomeClassifier {
    TestOutcomeClassifier { _ in bundleExists }
}

private func toolResult(exitCode: Int32 = 0, output: String = "", timedOut: Bool = false) -> ToolResult {
    ToolResult(exitCode: exitCode, output: output, timedOut: timedOut)
}
