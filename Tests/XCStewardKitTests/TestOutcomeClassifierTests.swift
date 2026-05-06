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
                .classify(run: toolResult(output: "Early unexpected exit", timedOut: true), resultBundle: resultBundle)
                .resultClass,
            .runnerBootstrapFailure
        )
        XCTAssertEqual(
            classifier(bundleExists: true)
                .classify(run: toolResult(output: "Testing started\nhang", timedOut: true), resultBundle: resultBundle)
                .resultClass,
            .testTimeout
        )
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
