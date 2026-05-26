import Foundation
import XCTest

final class ProfileValidationE2ETests: XCTestCase {
    func testInvalidParallelModeFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            mode = "bogus-mode"
            """,
            summaryMessage: "unsupported parallel.mode"
        )
    }

    func testInvalidParallelWorkerCountFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            max_workers = 0
            """,
            summaryMessage: "parallel.max_workers must be >= 1"
        )
    }

    func testInvalidTimeoutFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [timeouts]
            boot = 0
            """,
            summaryMessage: "timeouts.boot must be >= 1"
        )
    }

    func testBlankParallelModeFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            mode = " "
            """,
            summaryMessage: "parallel.mode must be a non-empty string"
        )
    }

    func testMalformedPrivacySectionFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [privacy]
            grant = "photos:com.example.app"
            """,
            summaryMessage: "privacy.grant must be an array of strings"
        )
    }

    func testMalformedEnvSectionFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [env]
            FOO = 1
            """,
            summaryMessage: "env.FOO must be a string"
        )
    }

    func testMalformedOutputArtifactSectionFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [result_bundle]
            version = "3"
            """,
            summaryMessage: "result_bundle.version must be an integer"
        )
    }

    func testInvalidResetPolicyFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            reset_policy = "shutdown-all"
            """,
            summaryMessage: "unsupported reset_policy"
        )
    }

    func testInvalidPortRangeFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            [ports]
            base = 65530
            count = 8
            stride = 8
            """,
            summaryMessage: "ports range exceeds 65535"
        )
    }

    func testInvalidPrivacyServiceFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [privacy]
            grant = ["bluetooth:com.example.Demo"]
            """,
            summaryMessage: "privacy.grant has unsupported service 'bluetooth'"
        )
    }

    func testInvalidPrivacyGrantWithoutBundleFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [privacy]
            grant = ["photos"]
            """,
            summaryMessage: "privacy.grant entry 'photos' requires a bundle identifier"
        )
    }

    func testInvalidXCTestTimeoutAllowanceFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_timeouts]
            default_execution_time_allowance = 300
            maximum_execution_time_allowance = 120
            """,
            summaryMessage: "test_timeouts.maximum_execution_time_allowance must be >= default_execution_time_allowance"
        )
    }

    func testInvalidDestinationTimeoutFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [destination]
            timeout = 0
            """,
            summaryMessage: "destination.timeout must be >= 1"
        )
    }

    func testInvalidCoverageSettingsFailConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [coverage]
            enabled = "yes"
            """,
            summaryMessage: "coverage.enabled must be a boolean"
        )
    }

    func testInvalidResultStreamSettingsFailConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [result_stream]
            enabled = "yes"
            """,
            summaryMessage: "result_stream.enabled must be a boolean"
        )
    }

    func testInvalidResultBundleVersionFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [result_bundle]
            version = 0
            """,
            summaryMessage: "result_bundle.version must be >= 1"
        )
    }

    func testInvalidXCTestRetrySettingsFailConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_retries]
            enabled = true
            iterations = 3
            retry_tests_on_failure = true
            run_tests_until_failure = true
            """,
            summaryMessage: "test_retries.retry_tests_on_failure and run_tests_until_failure are mutually exclusive"
        )
    }

    func testInvalidXCTestRetryRelaunchWithoutRetriesFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_retries]
            enabled = false
            relaunch_between_iterations = true
            """,
            summaryMessage: "test_retries.relaunch_between_iterations requires enabled = true"
        )
    }

    func testInvalidXCTestDiagnosticCollectionFailsConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_diagnostics]
            collect = "always"
            """,
            summaryMessage: "test_diagnostics.collect must be 'on-failure' or 'never'"
        )
    }

    func testInvalidTestProductsRuntimeSettingsFailConfiguration() throws {
        try assertInvalidProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            [test_products]
            enabled = false
            use_for_testing = true
            """,
            summaryMessage: "test_products.use_for_testing requires enabled = true"
        )
    }

    private func assertInvalidProfile(body: String, summaryMessage: String) throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(body: body)

        let result = try e2e.submit(wait: true)
        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertTrue((json["summary_line"] as? String)?.contains(summaryMessage) == true)
    }
}
