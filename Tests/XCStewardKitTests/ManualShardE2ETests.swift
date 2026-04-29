import Foundation
import XCTest

final class ManualShardE2ETests: XCTestCase {
    func testManualShardRunProducesDiagnosticsAndShardResultBundles() throws {
        let e2e = try E2EScenario(scenario: .manualShards)
        try e2e.writeProfile(
            body: """
            project_path = "App.xcodeproj"
            scheme = "Demo"
            default_simulator_id = "SIM-123"
            allowed_simulator_ids = ["SIM-123", "SIM-456"]
            [parallel]
            mode = "manual-shards"
            shard_count = 2
            [ports]
            base = 52000
            count = 4
            stride = 10
            """
        )

        let json = try e2e.submitJSON(wait: true)
        XCTAssertEqual(json["state"] as? String, "succeeded")
        XCTAssertEqual(json["result_class"] as? String, "success")
        XCTAssertEqual(json["summary_line"] as? String, "Manual shards succeeded (2 shards)")
        XCTAssertEqual((json["counts"] as? [String: Any])?["testsRun"] as? Int, 4)

        let artifacts = try XCTUnwrap(json["artifacts"] as? [String: Any])
        let mergedXCResult = try XCTUnwrap(artifacts["xcresult"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(mergedXCResult)/summary.json"))

        let diagnostics = try e2e.manualRunDiagnostics(from: artifacts)
        XCTAssertEqual(diagnostics.summary["result_class"] as? String, "success")
        XCTAssertEqual(diagnostics.summary["shard_count"] as? Int, 2)
        XCTAssertEqual(diagnostics.summary["retry_count"] as? Int, 0)
        XCTAssertEqual(diagnostics.summary["merged_result_bundle"] as? String, mergedXCResult)
        XCTAssertEqual(diagnostics.shards.count, 2)
        for report in diagnostics.shards {
            let resultBundle = try XCTUnwrap(report["result_bundle"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: "\(resultBundle)/summary.json"))
            XCTAssertEqual((report["only_testing"] as? [String])?.count, 2)
        }

        let shardLines = try e2e.xcodebuildLines(containing: "test-without-building")
            .filter { !$0.contains("-enumerate-tests") }
        XCTAssertEqual(shardLines.count, 2)
        XCTAssertTrue(shardLines.contains { $0.contains("-destination id=SIM-123") })
        XCTAssertTrue(shardLines.contains { $0.contains("-destination id=SIM-456") })
        for line in shardLines {
            XCTAssertTrue(line.contains("-parallel-testing-enabled NO"))
            XCTAssertTrue(line.contains("-maximum-parallel-testing-workers 1"))
            XCTAssertFalse(line.contains("-parallel-testing-worker-count"))
            XCTAssertTrue(line.contains("-only-testing:"))
        }
    }
}
