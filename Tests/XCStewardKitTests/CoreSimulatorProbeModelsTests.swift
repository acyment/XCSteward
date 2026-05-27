// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import XCTest
@testable import XCStewardKit

final class CoreSimulatorProbeModelsTests: XCTestCase {
    func testRuntimeProbeDecodesMixedAvailabilityForms() throws {
        let data = Data("""
        {
          "runtimes": [
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
              "name": "iOS 18.0",
              "isAvailable": "YES"
            },
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-4",
              "name": "iOS 17.4",
              "isAvailable": 0,
              "availabilityError": "dyld shared cache is missing"
            },
            {
              "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-18-0",
              "name": "tvOS 18.0",
              "isAvailable": true
            }
          ]
        }
        """.utf8)

        let probe = try JSONDecoder().decode(CoreSimulatorRuntimeListProbe.self, from: data)

        XCTAssertTrue(probe.runtimes[0].isIOSRuntime)
        XCTAssertTrue(probe.runtimes[0].isAvailable)
        XCTAssertTrue(probe.runtimes[1].isIOSRuntime)
        XCTAssertFalse(probe.runtimes[1].isAvailable)
        XCTAssertTrue(probe.runtimes[1].availabilityText.contains("dyld"))
        XCTAssertFalse(probe.runtimes[2].isIOSRuntime)
    }

    func testDeviceProbeDetectsUnavailableDevicesAcrossJSONShapes() throws {
        let data = Data("""
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
              {
                "name": "iPhone 17 Pro",
                "udid": "SIM-OK",
                "state": "Shutdown",
                "isAvailable": true
              },
              {
                "name": "Old iPhone",
                "udid": "SIM-OLD",
                "state": "Shutdown",
                "isAvailable": "NO"
              },
              {
                "name": "Text Old iPhone",
                "udid": "SIM-TEXT",
                "state": "Shutdown",
                "availability": "not available for this platform"
              },
              {
                "name": "Error Old iPhone",
                "udid": "SIM-ERR",
                "state": "Shutdown",
                "availability_error": "runtime is unavailable"
              }
            ]
          }
        }
        """.utf8)

        let probe = try JSONDecoder().decode(CoreSimulatorDeviceListProbe.self, from: data)
        let devices = try XCTUnwrap(probe.devices.values.first)

        XCTAssertFalse(devices[0].isUnavailable)
        XCTAssertTrue(devices[1].isUnavailable)
        XCTAssertEqual(devices[1].displayName, "Old iPhone SIM-OLD")
        XCTAssertTrue(devices[2].isUnavailable)
        XCTAssertTrue(devices[3].isUnavailable)
    }
}
