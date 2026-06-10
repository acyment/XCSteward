// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import XCTest
@testable import XCStewardKit

final class SubmitCommandOptionsTests: XCTestCase {
    func testParseCollectsSubmitOptionsIntoJobRequest() throws {
        let options = try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--wait",
            "--wait-timeout", "45",
            "--json",
            "--progress",
            "--test-plan", "Stable",
            "--simulator-id", "SIM-123",
            "--only-testing", "AppTests/FooTests/testA",
            "--only-testing", "AppTests/FooTests/testB",
            "--skip-testing", "AppTests/SlowTests",
            "--only-test-configuration", "Smoke",
            "--skip-test-configuration", "Flaky",
            "--env", "API_BASE_URL=http://127.0.0.1:8080",
            "--env", "FEATURE_FLAG=enabled",
            "--metadata", "agent=codex",
            "--metadata", "task=login-fix",
            "--label", "smoke",
        ])

        XCTAssertEqual(options.request.project, "demo")
        XCTAssertEqual(options.request.wait, true)
        XCTAssertEqual(options.waitTimeout, 45)
        XCTAssertEqual(options.json, true)
        XCTAssertEqual(options.progress, true)
        XCTAssertEqual(options.request.testPlan, "Stable")
        XCTAssertEqual(options.request.simulatorID, "SIM-123")
        XCTAssertEqual(options.request.onlyTesting, ["AppTests/FooTests/testA", "AppTests/FooTests/testB"])
        XCTAssertEqual(options.request.skipTesting, ["AppTests/SlowTests"])
        XCTAssertEqual(options.request.onlyTestConfigurations, ["Smoke"])
        XCTAssertEqual(options.request.skipTestConfigurations, ["Flaky"])
        XCTAssertEqual(options.request.envOverrides, [
            "API_BASE_URL": "http://127.0.0.1:8080",
            "FEATURE_FLAG": "enabled",
        ])
        XCTAssertEqual(options.request.metadata, [
            "agent": "codex",
            "task": "login-fix",
            "label": "smoke",
        ])
    }

    func testParseRejectsInvalidWaitTimeout() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--wait-timeout", "0",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --wait-timeout must be at least 1 second")
        }
    }

    func testParseRejectsUnexpectedArguments() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--bogus",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit received unexpected arguments: --bogus")
        }
    }

    func testParseRejectsMetadataWithoutEquals() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--metadata", "agent",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --metadata must be key=value")
        }
    }

    func testParseRejectsMetadataWithEmptyKeyOrValue() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--metadata", "=codex",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --metadata requires non-empty key and value")
        }

        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--metadata", "agent=",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --metadata requires non-empty key and value")
        }
    }

    func testParseRejectsDuplicateMetadataKeys() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--metadata", "agent=codex",
            "--metadata", "agent=cursor",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --metadata contains duplicate key 'agent'")
        }
    }

    func testParseRejectsMetadataKeyWithWhitespace() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--metadata", "bad key=value",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --metadata key must not contain whitespace")
        }
    }

    func testParseRejectsLabelConflict() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--metadata", "label=nightly",
            "--label", "smoke",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --label conflicts with --metadata label=...")
        }
    }

    func testParseRejectsEmptyLabel() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--label", "",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --label requires a non-empty value")
        }
    }

    func testParseRejectsInvalidEnvOverrides() throws {
        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--env", "NO_EQUALS",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --env must be KEY=VALUE")
        }

        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--env", "BAD-KEY=value",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --env key must match [A-Za-z_][A-Za-z0-9_]*")
        }

        XCTAssertThrowsError(try SubmitCommandOptions.parse(arguments: [
            "--project", "demo",
            "--env", "FLAG=one",
            "--env", "FLAG=two",
        ])) { error in
            XCTAssertEqual(String(describing: error), "submit --env contains duplicate key 'FLAG'")
        }
    }
}
