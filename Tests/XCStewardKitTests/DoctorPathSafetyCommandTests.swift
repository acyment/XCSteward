import Foundation
import XCTest

final class DoctorPathSafetyCommandTests: XCTestCase {
    func testDoctorWarnsWhenStateRootIsUnderProtectedPath() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: ["XCSTEWARD_DOCTOR_PROTECTED_PATHS": stateRoot.path]
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let protectedPath = try result.check("global.protected_path_warning")
        XCTAssertEqual(protectedPath["status"] as? String, "warn")
        XCTAssertEqual(protectedPath["auto_fixable"] as? Bool, false)
        XCTAssertEqual(protectedPath["fixed"] as? Bool, false)
        XCTAssertTrue((protectedPath["message"] as? String)?.contains("protected") == true)
        let manualAction = protectedPath["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Move XCSTEWARD_HOME or --state-root") == true)
        XCTAssertTrue(manualAction?.contains("unprotected developer-owned path") == true)
    }

    func testDoctorWarnsWhenProjectProfilePathsAreProtected() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let repoRoot = temp.appendingPathComponent("repo")
        let protectedOutput = temp.appendingPathComponent("protected-output")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .listSchemes,
            extraEnv: [
                "XCSTEWARD_DOCTOR_PROTECTED_PATHS": "\(repoRoot.path):\(protectedOutput.path)",
            ]
        )
        try createProfile(
            name: "protected-profile",
            stateRoot: stateRoot,
            repoRoot: repoRoot,
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            [env]
            DERIVED_DATA_PATH = "\(protectedOutput.appendingPathComponent("DerivedData").path)"
            """
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, project: "protected-profile", environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let protectedPath = try result.check("project.protected_path_warning")
        XCTAssertEqual(protectedPath["status"] as? String, "warn")
        XCTAssertEqual(protectedPath["auto_fixable"] as? Bool, false)
        XCTAssertEqual(protectedPath["fixed"] as? Bool, false)
        let message = try XCTUnwrap(protectedPath["message"] as? String)
        XCTAssertTrue(message.contains("repo_root"))
        XCTAssertTrue(message.contains("project_path"))
        XCTAssertTrue(message.contains("DERIVED_DATA_PATH"))
        let manualAction = protectedPath["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Move repo roots") == true)
        XCTAssertTrue(manualAction?.contains("explicit build output overrides") == true)
        XCTAssertTrue(manualAction?.contains("developer-owned paths") == true)
    }
}
