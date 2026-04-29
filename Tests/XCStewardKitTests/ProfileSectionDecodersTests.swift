import Foundation
import XCTest
@testable import XCStewardKit

final class ProfileSectionDecodersTests: XCTestCase {
    func testDecodesParallelDefaultsAndExplicitValues() throws {
        let defaults = try ProfileSectionDecoders.parallel(profileName: "demo", reader: section([:]))
        XCTAssertEqual(defaults.mode, .xcodeManaged)
        XCTAssertEqual(defaults.maxWorkers, 1)
        XCTAssertFalse(defaults.exactWorkers)
        XCTAssertEqual(defaults.shardCount, 1)

        let explicit = try ProfileSectionDecoders.parallel(profileName: "demo", reader: section([
            "mode": .string("manual-shards"),
            "max_workers": .integer(2),
            "exact_workers": .bool(true),
            "shard_count": .integer(3),
        ]))
        XCTAssertEqual(explicit.mode, .manualShards)
        XCTAssertEqual(explicit.maxWorkers, 2)
        XCTAssertTrue(explicit.exactWorkers)
        XCTAssertEqual(explicit.shardCount, 3)
    }

    func testDecodesPortsWithShardRangeValidation() throws {
        let ports = try XCTUnwrap(ProfileSectionDecoders.ports(
            profileName: "demo",
            reader: section([
                "base": .integer(9000),
                "count": .integer(8),
                "stride": .integer(20),
            ]),
            shardCount: 3
        ))
        XCTAssertEqual(ports.base, 9000)
        XCTAssertEqual(ports.count, 8)
        XCTAssertEqual(ports.stride, 20)

        XCTAssertThrowsError(try ProfileSectionDecoders.ports(
            profileName: "demo",
            reader: section([
                "base": .integer(65530),
                "count": .integer(8),
                "stride": .integer(8),
            ]),
            shardCount: 2
        )) { error in
            XCTAssertTrue(String(describing: error).contains("ports range exceeds 65535"))
        }
    }

    func testDecodesXCTestTimeoutRetryAndDiagnosticSections() throws {
        let timeouts = try ProfileSectionDecoders.xctestTimeouts(profileName: "demo", reader: section([
            "enabled": .bool(false),
            "default_execution_time_allowance": .integer(30),
            "maximum_execution_time_allowance": .integer(90),
        ]))
        XCTAssertFalse(timeouts.enabled)
        XCTAssertEqual(timeouts.defaultExecutionTimeAllowance, 30)
        XCTAssertEqual(timeouts.maximumExecutionTimeAllowance, 90)

        let retries = try ProfileSectionDecoders.xctestRetries(profileName: "demo", reader: section([
            "enabled": .bool(true),
            "iterations": .integer(3),
            "retry_tests_on_failure": .bool(false),
            "run_tests_until_failure": .bool(true),
            "relaunch_between_iterations": .bool(true),
        ]))
        XCTAssertTrue(retries.enabled)
        XCTAssertEqual(retries.iterations, 3)
        XCTAssertFalse(retries.retryTestsOnFailure)
        XCTAssertTrue(retries.runTestsUntilFailure)
        XCTAssertEqual(retries.relaunchBetweenIterations, true)

        let diagnostics = try ProfileSectionDecoders.xctestDiagnostics(profileName: "demo", reader: section([
            "collect": .string("on-failure"),
        ]))
        XCTAssertEqual(diagnostics.collect, .onFailure)
    }

    func testDecodesDestinationCoverageResultAndTestProductsSections() throws {
        let destination = try ProfileSectionDecoders.destination(profileName: "demo", reader: section([
            "timeout": .integer(45),
        ]))
        XCTAssertEqual(destination.timeout, 45)

        let coverage = try ProfileSectionDecoders.coverage(profileName: "demo", reader: section([
            "enabled": .bool(true),
        ]))
        XCTAssertEqual(coverage.enabled, true)

        let resultStream = try ProfileSectionDecoders.resultStream(profileName: "demo", reader: section([
            "enabled": .bool(true),
        ]))
        XCTAssertTrue(resultStream.enabled)

        let resultBundle = try ProfileSectionDecoders.resultBundle(profileName: "demo", reader: section([
            "version": .integer(3),
        ]))
        XCTAssertEqual(resultBundle.version, 3)

        let testProducts = try ProfileSectionDecoders.testProducts(profileName: "demo", reader: section([
            "enabled": .bool(true),
            "use_for_testing": .bool(true),
        ]))
        XCTAssertTrue(testProducts.enabled)
        XCTAssertTrue(testProducts.useForTesting)
    }

    func testDecodesPrivacyManagedSimulatorEnvTimeoutsAndResetPolicy() throws {
        let privacy = try ProfileSectionDecoders.privacy(profileName: "demo", reader: section([
            "grant": .array(["photos:com.example.app"]),
            "reset": .array(["all"]),
        ]))
        XCTAssertEqual(privacy.permissions.count, 2)
        XCTAssertEqual(privacy.permissions[0].action, .grant)
        XCTAssertEqual(privacy.permissions[0].service, "photos")
        XCTAssertEqual(privacy.permissions[0].bundleIdentifier, "com.example.app")
        XCTAssertEqual(privacy.permissions[1].action, .reset)
        XCTAssertEqual(privacy.permissions[1].service, "all")
        XCTAssertNil(privacy.permissions[1].bundleIdentifier)

        let managed = try XCTUnwrap(ProfileSectionDecoders.managedSimulator(reader: section([
            "name": .string("XCSteward iPhone"),
            "device_type": .string("com.apple.CoreSimulator.SimDeviceType.iPhone-16"),
            "runtime": .string("com.apple.CoreSimulator.SimRuntime.iOS-18-0"),
            "clone_for_shards": .bool(true),
        ])))
        XCTAssertEqual(managed.name, "XCSteward iPhone")
        XCTAssertTrue(managed.cloneForShards)

        XCTAssertEqual(ProfileSectionDecoders.env(reader: section([
            "DEVELOPER_DIR": .string("/Applications/Xcode.app"),
            "IGNORED": .integer(1),
        ])), ["DEVELOPER_DIR": "/Applications/Xcode.app"])

        let timeouts = ProfileSectionDecoders.timeouts(reader: section([
            "boot": .integer(10),
            "build": .integer(20),
            "test": .integer(30),
        ]))
        XCTAssertEqual(timeouts.boot, 10)
        XCTAssertEqual(timeouts.build, 20)
        XCTAssertEqual(timeouts.test, 30)

        let resetPolicy = try ProfileSectionDecoders.resetPolicy(profileName: "demo", root: section([
            "reset_policy": .string("Erase"),
        ]))
        XCTAssertEqual(resetPolicy, "erase")
    }
}

private func section(_ values: [String: TOMLValue]) -> TOMLSectionReader {
    TOMLSectionReader(values: values)
}
