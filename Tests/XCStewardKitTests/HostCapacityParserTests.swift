import Foundation
import XCTest
@testable import XCStewardKit

final class HostCapacityParserTests: XCTestCase {
    func testParsesMemoryPressureAndConstraintLevels() {
        let parser = HostCapacityParser()

        XCTAssertEqual(parser.parseMemoryPressure("System-wide memory status: WARNING"), "warning")
        XCTAssertEqual(parser.parseMemoryPressure("Memory pressure: critical"), "critical")
        XCTAssertEqual(parser.parseMemoryPressure("nominal"), "normal")
        XCTAssertNil(parser.parseMemoryPressure("unrecognized"))
        XCTAssertTrue(parser.isConstrainedMemoryPressure("warning"))
        XCTAssertFalse(parser.isConstrainedMemoryPressure("normal"))
    }

    func testParsesThermalStateFromTextAndNumericLevels() {
        let parser = HostCapacityParser()

        XCTAssertEqual(parser.parseThermalState("CPU_Speed_Limit = 49"), "critical")
        XCTAssertEqual(parser.parseThermalState("cpu_speed_limit = 75"), "serious")
        XCTAssertEqual(parser.parseThermalState("cpu_speed_limit = 95"), "fair")
        XCTAssertEqual(parser.parseThermalState("Thermal Warning Level: 2"), "serious")
        XCTAssertEqual(parser.parseThermalState("nominal"), "nominal")
        XCTAssertTrue(parser.isConstrainedThermalState("serious"))
        XCTAssertFalse(parser.isConstrainedThermalState("fair"))
    }

    func testCountsBootedSimulatorsInNestedSimctlJSON() throws {
        let data = Data(
            """
            {
              "devices": {
                "iOS 18.4": [
                  {"name": "A", "state": "Booted"},
                  {"name": "B", "state": "Shutdown"}
                ],
                "iOS 26.0": [
                  {"name": "C", "state": "booted"}
                ]
              }
            }
            """.utf8
        )

        XCTAssertEqual(HostCapacityParser().countBootedSimulators(in: data), 2)
    }

    func testNormalizesForeignActivityPolicyAndScalarValues() {
        let parser = HostCapacityParser()

        XCTAssertEqual(parser.normalizedForeignActivityPolicy(" strict "), "strict")
        XCTAssertEqual(parser.normalizedForeignActivityPolicy("ignore"), "ignore")
        XCTAssertEqual(parser.normalizedForeignActivityPolicy("unknown"), "capacity")
        XCTAssertEqual(parser.integer(" 42 "), 42)
        XCTAssertEqual(parser.double(" 2.5 "), 2.5)
        XCTAssertTrue(parser.bool("YES"))
        XCTAssertFalse(parser.bool("no"))
        XCTAssertEqual(parser.formatLoadAverage(12.345), "12.35")
    }
}
