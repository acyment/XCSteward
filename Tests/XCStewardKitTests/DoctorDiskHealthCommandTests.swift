// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest

final class DoctorDiskHealthCommandTests: XCTestCase {
    func testDoctorFailsWhenStateVolumeHasTooLittleFreeDiskSpace() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: [
                "XCSTEWARD_DOCTOR_MIN_FREE_BYTES": "\(Int64.max)",
                "XCSTEWARD_DOCTOR_WARN_FREE_BYTES": "\(Int64.max)",
            ]
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertNotEqual(result.cli.status, 0)
        XCTAssertEqual(result.overallStatus, "fail")
        let disk = try result.check("global.free_disk_space")
        XCTAssertEqual(disk["status"] as? String, "fail")
        XCTAssertTrue((disk["message"] as? String)?.contains("free") == true)
        let manualAction = disk["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("cleanup --dry-run") == true)
        XCTAssertTrue(manualAction?.contains("same --state-root") == true)
        XCTAssertTrue(manualAction?.contains("preserved evidence") == true)
    }

    func testDoctorWarnsWhenStateVolumeHasDiskPressure() throws {
        let temp = try makeTempDirectory()
        let stateRoot = temp.appendingPathComponent("state")
        let fakeTools = try makeFakeToolEnvironment(
            scenario: .success,
            extraEnv: ["XCSTEWARD_DOCTOR_WARN_FREE_PERCENT": "101"]
        )

        let result = try runDoctorCommand(stateRoot: stateRoot, environment: fakeTools.env)

        XCTAssertEqual(result.cli.status, 0, "stderr: \(result.cli.stderr)")
        XCTAssertEqual(result.overallStatus, "warn")
        let diskPressure = try result.check("global.disk_pressure_warning")
        XCTAssertEqual(diskPressure["status"] as? String, "warn")
        XCTAssertTrue((diskPressure["message"] as? String)?.contains("Disk pressure") == true)
        let manualAction = diskPressure["manual_action"] as? String
        XCTAssertTrue(manualAction?.contains("cleanup --dry-run") == true)
        XCTAssertTrue(manualAction?.contains("same --state-root") == true)
        XCTAssertTrue(manualAction?.contains("preserved evidence") == true)
    }
}
