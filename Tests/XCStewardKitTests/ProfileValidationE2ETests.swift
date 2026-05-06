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

    private func assertInvalidProfile(body: String, summaryMessage: String) throws {
        let e2e = try E2EScenario(scenario: .success)
        try e2e.writeProfile(body: body)

        let result = try e2e.submit(wait: true)
        XCTAssertNotEqual(result.status, 0)
        let json = try result.jsonObject()
        XCTAssertTrue((json["summary_line"] as? String)?.contains(summaryMessage) == true)
    }
}
