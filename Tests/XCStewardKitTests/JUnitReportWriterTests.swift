// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest
@testable import XCStewardKit

final class JUnitReportWriterTests: XCTestCase {
    func testBuildsEscapedXMLWithCountsAndRoundedDuration() {
        let xml = JUnitReportWriter().xml(
            project: "Demo & App",
            resultClass: .testFailure,
            counts: JobCounts(testsRun: 2, testsFailed: 1, testsSkipped: 0),
            durationSeconds: 1.23456,
            cases: [
                JUnitTestCase(
                    className: "DemoTests.FooTests",
                    name: "testEscapes<&>",
                    timeSeconds: 0.5,
                    failureMessage: "failed <because>",
                    errorMessage: nil,
                    skipped: false
                ),
            ]
        )

        XCTAssertTrue(xml.contains("name=\"Demo &amp; App\""))
        XCTAssertTrue(xml.contains("tests=\"2\""))
        XCTAssertTrue(xml.contains("failures=\"1\""))
        XCTAssertTrue(xml.contains("time=\"1.235\""))
        XCTAssertTrue(xml.contains("testEscapes&lt;&amp;&gt;"))
        XCTAssertTrue(xml.contains("failed &lt;because&gt;"))
    }

    func testBuildsSingleRunCasesFromExplicitIdentifiersAndCounts() {
        let cases = JUnitReportWriter().casesForSingleRun(
            resultClass: .testFailure,
            counts: JobCounts(testsRun: 3, testsFailed: 1, testsSkipped: 1),
            onlyTesting: [
                "DemoTests/FooTests/testA",
                "DemoTests/FooTests/testB",
                "DemoTests/BarTests/testC",
            ]
        )

        XCTAssertEqual(cases.map(\.className), ["DemoTests.FooTests", "DemoTests.FooTests", "DemoTests.BarTests"])
        XCTAssertEqual(cases.map(\.name), ["testA", "testB", "testC"])
        XCTAssertEqual(cases.map { $0.failureMessage != nil }, [true, false, false])
        XCTAssertEqual(cases.map(\.skipped), [false, true, false])
    }

    func testBuildsPlaceholderCasesWhenOnlyTestingIsAbsent() {
        let cases = JUnitReportWriter().casesForSingleRun(
            resultClass: .success,
            counts: JobCounts(testsRun: 2, testsFailed: 0, testsSkipped: 0),
            onlyTesting: []
        )

        XCTAssertEqual(cases.map(\.className), ["xcresult-summary", "xcresult-summary"])
        XCTAssertEqual(cases.map(\.name), ["test-001", "test-002"])
    }

    func testBuildsShardErrorCaseWhenShardHasNoCounts() {
        let cases = JUnitReportWriter().casesForShardReports([
            ShardReport(
                shardID: "shard-000",
                simulatorID: "SIM-1",
                onlyTesting: [],
                resultBundle: "/tmp/shard-000.xcresult",
                resultStream: nil,
                log: "/tmp/shard-000.log",
                resultClass: .runnerBootstrapFailure,
                exitCode: 65,
                counts: nil,
                attempts: 1,
                retryReason: nil,
                simulatorDiagnostics: []
            ),
        ])

        XCTAssertEqual(cases.count, 1)
        XCTAssertEqual(cases[0].className, "XCSteward.shard-000")
        XCTAssertEqual(cases[0].name, "runner_bootstrap_failure")
        XCTAssertEqual(cases[0].errorMessage, "Runner failed before tests executed")
    }
}
