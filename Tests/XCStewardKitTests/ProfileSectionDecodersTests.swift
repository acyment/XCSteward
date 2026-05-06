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

    func testNormalizesEnumLikeProfileStrings() throws {
        let parallel = try ProfileSectionDecoders.parallel(profileName: "demo", reader: section([
            "mode": .string(" Manual-Shards "),
        ]))
        XCTAssertEqual(parallel.mode, .manualShards)

        let diagnostics = try ProfileSectionDecoders.xctestDiagnostics(profileName: "demo", reader: section([
            "collect": .string(" NEVER\n"),
        ]))
        XCTAssertEqual(diagnostics.collect, .never)

        let resetPolicy = try ProfileSectionDecoders.resetPolicy(profileName: "demo", root: section([
            "reset_policy": .string(" Shutdown "),
        ]))
        XCTAssertEqual(resetPolicy, "shutdown")
    }

    func testRejectsBlankEnumLikeProfileStrings() throws {
        XCTAssertThrowsError(try ProfileSectionDecoders.parallel(profileName: "demo", reader: section([
            "mode": .string(" "),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("parallel.mode must be a non-empty string"))
        }

        XCTAssertThrowsError(try ProfileSectionDecoders.xctestDiagnostics(profileName: "demo", reader: section([
            "collect": .string("\n"),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("test_diagnostics.collect must be a non-empty string"))
        }

        XCTAssertThrowsError(try ProfileSectionDecoders.resetPolicy(profileName: "demo", root: section([
            "reset_policy": .string("\t"),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("reset_policy must be a non-empty string"))
        }
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

    func testRejectsMalformedOutputAndArtifactSections() throws {
        XCTAssertThrowsError(try ProfileSectionDecoders.coverage(profileName: "demo", reader: section([
            "enabled": .string("yes"),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("coverage.enabled must be a boolean"))
        }

        XCTAssertThrowsError(try ProfileSectionDecoders.resultStream(profileName: "demo", reader: section([
            "enabled": .bool(true),
            "path": .string("result-stream.json"),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("[result_stream] has unsupported key 'path'"))
        }

        XCTAssertThrowsError(try ProfileSectionDecoders.resultBundle(profileName: "demo", reader: section([
            "version": .string("3"),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("result_bundle.version must be an integer"))
        }

        XCTAssertThrowsError(try ProfileSectionDecoders.testProducts(profileName: "demo", reader: section([
            "enabled": .string("true"),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("test_products.enabled must be a boolean"))
        }
    }

    func testDecodesPrivacyManagedSimulatorEnvTimeoutsAndResetPolicy() throws {
        let privacy = try ProfileSectionDecoders.privacy(profileName: "demo", reader: section([
            "grant": .array([" Photos : com.example.app "]),
            "reset": .array(["all"]),
        ]))
        XCTAssertEqual(privacy.permissions.count, 2)
        XCTAssertEqual(privacy.permissions[0].action, .grant)
        XCTAssertEqual(privacy.permissions[0].service, "photos")
        XCTAssertEqual(privacy.permissions[0].bundleIdentifier, "com.example.app")
        XCTAssertEqual(privacy.permissions[1].action, .reset)
        XCTAssertEqual(privacy.permissions[1].service, "all")
        XCTAssertNil(privacy.permissions[1].bundleIdentifier)

        let managed = try XCTUnwrap(try ProfileSectionDecoders.managedSimulator(profileName: "demo", reader: section([
            "name": .string("XCSteward iPhone"),
            "device_type": .string("com.apple.CoreSimulator.SimDeviceType.iPhone-16"),
            "runtime": .string("com.apple.CoreSimulator.SimRuntime.iOS-18-0"),
            "clone_for_shards": .bool(true),
        ])))
        XCTAssertEqual(managed.name, "XCSteward iPhone")
        XCTAssertTrue(managed.cloneForShards)

        XCTAssertEqual(try ProfileSectionDecoders.env(profileName: "demo", reader: section([
            "DEVELOPER_DIR": .string("/Applications/Xcode.app"),
            "SPACED": .string(" value with surrounding spaces "),
        ])), [
            "DEVELOPER_DIR": "/Applications/Xcode.app",
            "SPACED": " value with surrounding spaces ",
        ])

        let timeouts = try ProfileSectionDecoders.timeouts(profileName: "demo", reader: section([
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

    func testRejectsMalformedPrivacySection() throws {
        XCTAssertThrowsError(try ProfileSectionDecoders.privacy(profileName: "demo", reader: section([
            "grant": .string("photos:com.example.app"),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("privacy.grant must be an array of strings"))
        }

        XCTAssertThrowsError(try ProfileSectionDecoders.privacy(profileName: "demo", reader: section([
            "allow": .array(["photos:com.example.app"]),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("[privacy] has unsupported key 'allow'"))
        }
    }

    func testRejectsMalformedEnvSection() throws {
        XCTAssertThrowsError(try ProfileSectionDecoders.env(profileName: "demo", reader: section([
            "DEVELOPER_DIR": .string("/Applications/Xcode.app"),
            "IGNORED": .integer(1),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("env.IGNORED must be a string"))
        }
    }

    func testRejectsNonPositiveTimeouts() throws {
        XCTAssertThrowsError(try ProfileSectionDecoders.timeouts(profileName: "demo", reader: section([
            "boot": .integer(0),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("timeouts.boot must be >= 1"))
        }

        XCTAssertThrowsError(try ProfileSectionDecoders.timeouts(profileName: "demo", reader: section([
            "build": .integer(-1),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("timeouts.build must be >= 1"))
        }

        XCTAssertThrowsError(try ProfileSectionDecoders.timeouts(profileName: "demo", reader: section([
            "test": .integer(0),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("timeouts.test must be >= 1"))
        }
    }

    func testManagedSimulatorTrimsRequiredStrings() throws {
        let managed = try XCTUnwrap(try ProfileSectionDecoders.managedSimulator(profileName: "demo", reader: section([
            "name": .string("  XCSteward iPhone  "),
            "device_type": .string("  iPhone 17 Pro\n"),
            "runtime": .string("\tiOS 18.0  "),
        ])))

        XCTAssertEqual(managed.name, "XCSteward iPhone")
        XCTAssertEqual(managed.deviceType, "iPhone 17 Pro")
        XCTAssertEqual(managed.runtime, "iOS 18.0")
    }

    func testManagedSimulatorRejectsPartialOrBlankSection() throws {
        XCTAssertThrowsError(try ProfileSectionDecoders.managedSimulator(profileName: "demo", reader: section([
            "name": .string("XCSteward iPhone"),
            "runtime": .string("iOS 18.0"),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("managed_simulator.device_type must be a non-empty string"))
        }

        XCTAssertThrowsError(try ProfileSectionDecoders.managedSimulator(profileName: "demo", reader: section([
            "name": .string(" "),
            "device_type": .string("iPhone 17 Pro"),
            "runtime": .string("iOS 18.0"),
        ]))) { error in
            XCTAssertTrue(String(describing: error).contains("managed_simulator.name must be a non-empty string"))
        }
    }
}

private func section(_ values: [String: TOMLValue]) -> TOMLSectionReader {
    TOMLSectionReader(values: values)
}
