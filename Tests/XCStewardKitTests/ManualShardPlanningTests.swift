// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest
@testable import XCStewardKit

final class ManualShardPlanningTests: XCTestCase {
    func testSimulatorPlanNormalizesDeduplicatesAndSelectsConfiguredIDs() throws {
        let planner = ManualShardPlanner()

        let plan = planner.simulatorPlan(
            primarySimulatorID: " SIM-1 ",
            requestedSimulatorID: "SIM-2",
            defaultSimulatorID: "SIM-2",
            allowedSimulatorIDs: ["", " SIM-3 ", "SIM-1"],
            requiredCount: 2
        )

        XCTAssertEqual(plan.configuredSimulatorIDs, ["SIM-1", "SIM-2", "SIM-3"])
        XCTAssertEqual(plan.cloneDeficit, 0)
        let selection = try XCTUnwrap(planner.configuredSimulatorSelection(from: plan))
        XCTAssertEqual(selection.simulatorIDs, ["SIM-1", "SIM-2"])
        XCTAssertEqual(selection.transientSimulatorIDs, [])
        XCTAssertFalse(selection.primaryNeedsBoot)
    }

    func testSimulatorPlanReportsCloneDeficitWhenConfiguredIDsAreInsufficient() {
        let plan = ManualShardPlanner().simulatorPlan(
            primarySimulatorID: "SIM-1",
            requestedSimulatorID: nil,
            defaultSimulatorID: nil,
            allowedSimulatorIDs: [],
            requiredCount: 3
        )

        XCTAssertEqual(plan.configuredSimulatorIDs, ["SIM-1"])
        XCTAssertEqual(plan.cloneDeficit, 2)
        XCTAssertNil(ManualShardPlanner().configuredSimulatorSelection(from: plan))
    }

    func testParsesEnumeratedIdentifiersFromNestedJSONAndDeduplicates() throws {
        let data = Data(
            """
            {
              "tests": [
                {"identifier": " DemoTests/FooTests/testA "},
                {"children": [
                  {"testIdentifier": "DemoTests/BarTests/testB"},
                  {"identifier": "DemoTests/FooTests/testA"},
                  {"identifier": "   "}
                ]}
              ]
            }
            """.utf8
        )

        let identifiers = try ManualShardPlanner().parseEnumeratedTestIdentifiers(from: data)

        XCTAssertEqual(identifiers, [
            "DemoTests/FooTests/testA",
            "DemoTests/BarTests/testB",
        ])
    }

    func testParsesQualifiedEnumerationNamesAndStringListsConservatively() throws {
        let data = Data(
            """
            {
              "metadata": {"name": "DemoApp"},
              "tests": [
                {"name": "DemoTests/BazTests/testC"},
                {"name": "Human readable suite"},
                {"testNames": [
                  " DemoTests/QuxTests/testD ",
                  "not a test identifier"
                ]},
                "DemoTests/ListTests/testE",
                "display text"
              ]
            }
            """.utf8
        )

        let identifiers = try ManualShardPlanner().parseEnumeratedTestIdentifiers(from: data)

        XCTAssertEqual(identifiers, [
            "DemoTests/BazTests/testC",
            "DemoTests/QuxTests/testD",
            "DemoTests/ListTests/testE",
        ])
    }

    func testFiltersEnumeratedIdentifiersWithSkipFilters() {
        let identifiers = ManualShardPlanner().filterEnumeratedTestIdentifiers(
            [
                "DemoTests/LoginTests/testSuccess",
                "DemoTests/LoginTests/testFailure",
                "DemoTests/CheckoutTests/testPurchase",
            ],
            skipTesting: ["DemoTests/LoginTests"]
        ) { identifier, skip in
            identifier == skip || identifier.hasPrefix("\(skip)/")
        }

        XCTAssertEqual(identifiers, ["DemoTests/CheckoutTests/testPurchase"])
    }

    func testSplitsIdentifiersRoundRobinWhenNoTimingHistoryExists() {
        let groups = ManualShardPlanner().splitTestIdentifiers(
            ["A", "B", "C", "D", "E"],
            shardCount: 2
        )

        XCTAssertEqual(groups, [
            ["A", "C", "E"],
            ["B", "D"],
        ])
    }

    func testSplitsIdentifiersByTimingHistoryWhenAvailable() {
        let groups = ManualShardPlanner().splitTestIdentifiers(
            ["slow", "fast1", "fast2", "unknown"],
            shardCount: 2,
            timingEstimates: [
                "slow": 10,
                "fast1": 1,
                "fast2": 1,
            ]
        )

        XCTAssertEqual(groups, [
            ["slow"],
            ["unknown", "fast1", "fast2"],
        ])
    }

    func testAggregatesResultClassByShardFailurePrecedence() {
        let planner = ManualShardPlanner()

        XCTAssertEqual(planner.aggregateResultClass([.success, .testFailure]), .testFailure)
        XCTAssertEqual(planner.aggregateResultClass([.testFailure, .artifactFailure]), .artifactFailure)
        XCTAssertEqual(planner.aggregateResultClass([.buildFailure, .buildTimeout]), .buildTimeout)
        XCTAssertEqual(planner.aggregateResultClass([.internalError, .buildFailure]), .buildFailure)
        XCTAssertEqual(planner.aggregateResultClass([.success, .canceled, .buildFailure]), .canceled)
        XCTAssertEqual(planner.aggregateResultClass([.success, .success]), .success)
    }
}
