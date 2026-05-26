import Foundation
import XCTest

final class DoctorXcodeEnvironmentCommandTests: XCTestCase {
    func testDoctorFailsWhenSelectedDeveloperDirIsCommandLineTools() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .commandLineToolsSelection)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let selection = try result.check("global.clt_vs_xcode_selection")
        XCTAssertEqual(selection["status"] as? String, "fail")
        XCTAssertEqual(selection["auto_fixable"] as? Bool, false)
        XCTAssertEqual(selection["fixed"] as? Bool, false)
        XCTAssertTrue((selection["message"] as? String)?.contains("Command Line Tools") == true)
        let manualAction = selection["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("xcode-select --switch") == true)
        XCTAssertTrue(manualAction?.contains("Xcode.app") == true)
    }

    func testDoctorWarnsWhenDeveloperDirEnvironmentOverridesSelectedXcode() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: ["DEVELOPER_DIR": "/Applications/AltXcode.app/Contents/Developer"]
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let override = try result.check("global.developer_dir_env_override")
        XCTAssertEqual(override["status"] as? String, "warn")
        XCTAssertEqual(override["auto_fixable"] as? Bool, false)
        XCTAssertEqual(override["fixed"] as? Bool, false)
        XCTAssertTrue((override["message"] as? String)?.contains("DEVELOPER_DIR") == true)
        let manualAction = override["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Unset DEVELOPER_DIR") == true)
        XCTAssertTrue(manualAction?.contains("selected Xcode.app") == true)
    }

    func testDoctorFailsWhenFirstLaunchComponentsAreMissing() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingFirstLaunchComponents)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let components = try result.check("global.first_launch_components")
        XCTAssertEqual(components["status"] as? String, "fail")
        XCTAssertEqual(components["auto_fixable"] as? Bool, false)
        XCTAssertEqual(components["fixed"] as? Bool, false)
        XCTAssertTrue((components["message"] as? String)?.contains("first-launch") == true)
        XCTAssertTrue((components["message"] as? String)?.contains("simctl") == true)
        let manualAction = components["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("xcodebuild -runFirstLaunch") == true)
    }

    func testDoctorFailsWhenIPhoneSimulatorSDKIsMissing() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .missingIPhoneSimulatorSDK)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let sdk = try result.check("global.iphonesimulator_sdk_present")
        XCTAssertEqual(sdk["status"] as? String, "fail")
        XCTAssertEqual(sdk["auto_fixable"] as? Bool, false)
        XCTAssertEqual(sdk["fixed"] as? Bool, false)
        XCTAssertTrue((sdk["message"] as? String)?.contains("iphonesimulator") == true)
        let manualAction = sdk["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Install iOS Simulator platform support") == true)
        XCTAssertTrue(manualAction?.contains("selected Xcode") == true)
    }

    func testDoctorDoesNotAcceptShowSDKsWarningAsSimulatorSDK() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .showsdksWarningOnly)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let sdk = try result.check("global.iphonesimulator_sdk_present")
        XCTAssertEqual(sdk["status"] as? String, "fail")
    }

    func testDoctorFallsBackToPlatformBundleWhenShowSDKsFails() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .showsdksFailureWithSDKOnDisk)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let sdk = try result.check("global.iphonesimulator_sdk_present")
        XCTAssertEqual(sdk["status"] as? String, "pass")
        XCTAssertTrue((sdk["message"] as? String)?.contains("xcodebuild -showsdks failed") == true)
        let compatibility = try result.check("global.iphonesimulator_runtime_compatible")
        XCTAssertEqual(compatibility["status"] as? String, "warn")
        XCTAssertTrue((compatibility["message"] as? String)?.contains("xcodebuild -showsdks failed") == true)
    }

    func testDoctorFailsWhenSelectedXcodeAndCLICommandVersionsDiffer() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .xcodeVersionMismatch)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let alignment = try result.check("global.xcode_cli_alignment")
        XCTAssertEqual(alignment["status"] as? String, "fail")
        XCTAssertEqual(alignment["auto_fixable"] as? Bool, false)
        XCTAssertEqual(alignment["fixed"] as? Bool, false)
        XCTAssertTrue((alignment["message"] as? String)?.contains("does not match") == true)
        XCTAssertTrue((alignment["message"] as? String)?.contains("xcodebuild version") == true)
        let manualAction = alignment["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("xcode-select --switch") == true)
        XCTAssertTrue(manualAction?.contains("intended Xcode.app") == true)
    }
}
