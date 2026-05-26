import Foundation
import XCTest

final class DoctorCoreSimulatorCommandTests: XCTestCase {
    func testDoctorFailsWhenNoAvailableSimulatorRuntimeIsInstalled() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .noAvailableSimulatorRuntime)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let runtime = try result.check("global.simulator_runtime_installed")
        XCTAssertEqual(runtime["status"] as? String, "fail")
        XCTAssertEqual(runtime["auto_fixable"] as? Bool, false)
        XCTAssertEqual(runtime["fixed"] as? Bool, false)
        XCTAssertTrue((runtime["message"] as? String)?.contains("runtime") == true)
        let manualAction = runtime["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Install an iOS Simulator runtime") == true)
        XCTAssertTrue(manualAction?.contains("selected Xcode") == true)
    }

    func testDoctorFailsWhenIPhoneSimulatorSDKAndRuntimeVersionsDoNotMatch() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .iPhoneSimulatorSDKRuntimeMismatch)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let compatibility = try result.check("global.iphonesimulator_runtime_compatible")
        XCTAssertEqual(compatibility["status"] as? String, "fail")
        XCTAssertEqual(compatibility["auto_fixable"] as? Bool, false)
        XCTAssertEqual(compatibility["fixed"] as? Bool, false)
        XCTAssertTrue((compatibility["message"] as? String)?.contains("iphonesimulator SDK 18.0") == true)
        XCTAssertTrue((compatibility["message"] as? String)?.contains("iOS Simulator runtimes are 17.4") == true)
        let manualAction = compatibility["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Install a matching iOS Simulator runtime") == true)
        XCTAssertTrue(manualAction?.contains("switch xcode-select") == true)
    }

    func testDoctorParsesTextualSimulatorRuntimeAvailability() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .textualSimulatorRuntimeAvailability)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let installed = try result.check("global.simulator_runtime_installed")
        XCTAssertEqual(installed["status"] as? String, "pass")
        let unavailable = try result.check("global.simulator_runtime_unavailable")
        XCTAssertEqual(unavailable["status"] as? String, "warn")
        XCTAssertEqual(unavailable["auto_fixable"] as? Bool, false)
        XCTAssertEqual(unavailable["fixed"] as? Bool, false)
        XCTAssertTrue((unavailable["message"] as? String)?.contains("ios 17.4") == true)
        let dyld = try result.check("global.runtime_dyld_cache_state")
        XCTAssertEqual(dyld["status"] as? String, "fail")
        XCTAssertEqual(dyld["auto_fixable"] as? Bool, false)
        XCTAssertEqual(dyld["fixed"] as? Bool, false)
        XCTAssertTrue((dyld["message"] as? String)?.contains("dyld") == true)
        XCTAssertTrue((dyld["manual_action"] as? String)?.contains("refresh Xcode runtime support") == true)
    }

    func testDoctorDoesNotAcceptNegativeTextualSimulatorRuntimeAvailability() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .negativeTextSimulatorRuntimeAvailability)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let installed = try result.check("global.simulator_runtime_installed")
        XCTAssertEqual(installed["status"] as? String, "fail")
        XCTAssertEqual(installed["auto_fixable"] as? Bool, false)
        XCTAssertEqual(installed["fixed"] as? Bool, false)
        XCTAssertTrue((installed["message"] as? String)?.contains("No available iOS Simulator runtime") == true)
    }

    func testDoctorParsesSimulatorRuntimeAvailabilityFlags() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .flagSimulatorRuntimeAvailability)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let installed = try result.check("global.simulator_runtime_installed")
        XCTAssertEqual(installed["status"] as? String, "pass")
        let unavailable = try result.check("global.simulator_runtime_unavailable")
        XCTAssertEqual(unavailable["status"] as? String, "warn")
        XCTAssertEqual(unavailable["auto_fixable"] as? Bool, false)
        XCTAssertEqual(unavailable["fixed"] as? Bool, false)
        XCTAssertTrue((unavailable["message"] as? String)?.contains("ios 17.4") == true)
    }

    func testDoctorWarnsWhenInstalledSimulatorRuntimeIsUnavailable() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .unavailableSimulatorRuntime)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let runtime = try result.check("global.simulator_runtime_unavailable")
        XCTAssertEqual(runtime["status"] as? String, "warn")
        XCTAssertEqual(runtime["auto_fixable"] as? Bool, false)
        XCTAssertEqual(runtime["fixed"] as? Bool, false)
        XCTAssertTrue((runtime["message"] as? String)?.contains("unavailable") == true)
        XCTAssertTrue((runtime["message"] as? String)?.contains("iOS 17.4") == true)
        let manualAction = runtime["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Reinstall") == true)
        XCTAssertTrue(manualAction?.contains("selected Xcode") == true)
    }

    func testDoctorFailsWhenSimulatorRuntimeReportsDyldCacheError() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .runtimeDyldCacheUnavailable)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let dyld = try result.check("global.runtime_dyld_cache_state")
        XCTAssertEqual(dyld["status"] as? String, "fail")
        XCTAssertEqual(dyld["auto_fixable"] as? Bool, false)
        XCTAssertEqual(dyld["fixed"] as? Bool, false)
        XCTAssertTrue((dyld["message"] as? String)?.contains("dyld") == true)
        let manualAction = dyld["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("Reinstall") == true)
        XCTAssertTrue(manualAction?.contains("refresh Xcode runtime support") == true)
    }

    func testDoctorWarnsWhenUnavailableSimulatorDevicesExist() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .unavailableSimulatorDevice)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let devices = try result.check("global.unavailable_devices_cleanup")
        XCTAssertEqual(devices["status"] as? String, "warn")
        XCTAssertEqual(devices["auto_fixable"] as? Bool, true)
        XCTAssertEqual(devices["fixed"] as? Bool, false)
        XCTAssertTrue((devices["message"] as? String)?.contains("Old iPhone") == true)
        XCTAssertTrue((devices["manual_action"] as? String)?.contains("--dangerously-confirm-global-coresimulator-cleanup") == true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertFalse(log.contains("xcrun simctl delete unavailable"))
    }

    func testDoctorWarnsWhenTextualUnavailableSimulatorDevicesExist() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .textualUnavailableSimulatorDevice)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let devices = try result.check("global.unavailable_devices_cleanup")
        XCTAssertEqual(devices["status"] as? String, "warn")
        XCTAssertEqual(devices["auto_fixable"] as? Bool, true)
        XCTAssertEqual(devices["fixed"] as? Bool, false)
        XCTAssertTrue((devices["message"] as? String)?.contains("Text Old iPhone") == true)
        XCTAssertTrue((devices["message"] as? String)?.contains("Snake Old iPhone") == true)
        XCTAssertTrue((devices["manual_action"] as? String)?.contains("--dangerously-confirm-global-coresimulator-cleanup") == true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertFalse(log.contains("xcrun simctl delete unavailable"))
    }

    func testDoctorWarnsWhenUnavailableSimulatorDeviceFlagsExist() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .flagUnavailableSimulatorDevice)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let devices = try result.check("global.unavailable_devices_cleanup")
        XCTAssertEqual(devices["status"] as? String, "warn")
        XCTAssertEqual(devices["auto_fixable"] as? Bool, true)
        XCTAssertEqual(devices["fixed"] as? Bool, false)
        XCTAssertTrue((devices["message"] as? String)?.contains("Int Old iPhone") == true)
        XCTAssertTrue((devices["message"] as? String)?.contains("No Old iPhone") == true)
        XCTAssertTrue((devices["manual_action"] as? String)?.contains("--dangerously-confirm-global-coresimulator-cleanup") == true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertFalse(log.contains("xcrun simctl delete unavailable"))
    }

    func testDoctorWarnsWithoutAutoFixWhenUnavailableDeviceInspectionFails() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .coreSimulatorDeviceListFailure)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let devices = try result.check("global.unavailable_devices_cleanup")
        XCTAssertEqual(devices["status"] as? String, "warn")
        XCTAssertEqual(devices["auto_fixable"] as? Bool, false)
        XCTAssertEqual(devices["fixed"] as? Bool, false)
        XCTAssertTrue((devices["message"] as? String)?.contains("Unable to inspect unavailable Simulator devices") == true)
        let manualAction = devices["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("xcrun simctl list devices --json") == true)
        XCTAssertTrue(manualAction?.contains("CoreSimulator errors") == true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertFalse(log.contains("xcrun simctl delete unavailable"))
    }

    func testDoctorFixDoesNotDeleteUnavailableSimulatorDevices() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .unavailableSimulatorDevice)

        let result = try runDoctorCommand(stateRoot: stateRoot, fix: true, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let devices = try result.check("global.unavailable_devices_cleanup")
        XCTAssertEqual(devices["status"] as? String, "warn")
        XCTAssertEqual(devices["fixed"] as? Bool, false)
        XCTAssertTrue((devices["manual_action"] as? String)?.contains("--fix-global") == true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertFalse(log.contains("xcrun simctl delete unavailable"))
    }

    func testDoctorFixGlobalDeletesUnavailableSimulatorDevices() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .unavailableSimulatorDevice)

        let result = try runDoctorCommand(
            stateRoot: stateRoot,
            fixGlobal: true,
            confirmGlobalCleanup: true,
            environment: fakeTools.env
        )

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "pass")
        let devices = try result.check("global.unavailable_devices_cleanup")
        XCTAssertEqual(devices["status"] as? String, "pass")
        XCTAssertEqual(devices["fixed"] as? Bool, true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertTrue(log.contains("xcrun simctl delete unavailable"))
    }

    func testDoctorFixGlobalRequiresDangerConfirmationBeforeDeletingUnavailableSimulatorDevices() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .unavailableSimulatorDevice)

        let result = try runCLI(arguments: [
            "doctor",
            "--state-root", stateRoot.path,
            "--fix-global",
            "--json",
        ], environment: fakeTools.env)

        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.stdout, "")
        let envelope = try XCTUnwrap(parseJSON(result.stderr) as? [String: Any])
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "usage")
        XCTAssertTrue((error["message"] as? String)?.contains("--dangerously-confirm-global-coresimulator-cleanup") == true)
        let log = FileManager.default.fileExists(atPath: fakeTools.log.path)
            ? try String(contentsOf: fakeTools.log)
            : ""
        XCTAssertFalse(log.contains("xcrun simctl delete unavailable"))
    }

    func testDoctorFailsWhenCoreSimulatorJsonEnumerationHangs() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(scenario: .hungCoreSimulatorList)

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let coreSim = try result.check("global.coresim_list_json_health")
        XCTAssertEqual(coreSim["status"] as? String, "fail")
        XCTAssertEqual(coreSim["auto_fixable"] as? Bool, false)
        XCTAssertEqual(coreSim["fixed"] as? Bool, false)
        XCTAssertTrue((coreSim["message"] as? String)?.contains("simctl list --json") == true)
        XCTAssertTrue((coreSim["manual_action"] as? String)?.contains("Inspect CoreSimulator health") == true)
        let log = try String(contentsOf: fakeTools.log)
        XCTAssertFalse(log.contains("xcrun simctl delete unavailable"))
    }
}
