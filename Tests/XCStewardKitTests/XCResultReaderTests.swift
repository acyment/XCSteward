import Foundation
import XCTest
@testable import XCStewardKit

final class XCResultReaderTests: XCTestCase {
    func testParserDecodesLegacyAndModernSummaries() throws {
        let parser = XCResultParser()

        let legacy = try XCTUnwrap(parser.summary(from: Data(#"{"testsCount":2,"testsFailedCount":1,"testsSkippedCount":0}"#.utf8)))
        let modern = try XCTUnwrap(parser.summary(from: Data(#"{"totalTestCount":3,"failedTests":0,"skippedTests":1}"#.utf8)))

        XCTAssertEqual(legacy.testsCount, 2)
        XCTAssertEqual(legacy.testsFailedCount, 1)
        XCTAssertEqual(modern.testsCount, 3)
        XCTAssertEqual(modern.testsSkippedCount, 1)
    }

    func testParserExtractsTimingSamplesFromNestedJSON() throws {
        let data = Data(
            """
            {
              "suites": [
                {"identifier": "DemoTests/FooTests/testA", "duration": 1.25},
                {"children": [
                  {"name": "DemoTests/BarTests/testB", "time_seconds": "2.5"},
                  {"identifier": "IgnoredWithoutDuration"}
                ]}
              ]
            }
            """.utf8
        )

        let timings = try XCResultParser().testTimingSamples(from: data)

        XCTAssertEqual(timings.map(\.identifier), ["DemoTests/BarTests/testB", "DemoTests/FooTests/testA"])
        XCTAssertEqual(timings.map(\.durationSeconds), [2.5, 1.25])
    }

    func testReaderInvokesModernXCResultToolCommands() throws {
        let temp = try makeTempDirectory()
        let resultBundle = temp.appendingPathComponent("result.xcresult")
        try FileManager.default.createDirectory(at: resultBundle, withIntermediateDirectories: true)
        var commands: [[String]] = []
        let runner = StubToolRunner { _, arguments in
            commands.append(arguments)
            if arguments.contains("summary") {
                return ToolResult(exitCode: 0, output: #"{"totalTestCount":1,"failedTests":0,"skippedTests":0}"#, timedOut: false)
            }
            if arguments.contains("tests") {
                return ToolResult(exitCode: 0, output: #"{"tests":[{"identifier":"DemoTests/FooTests/testA","duration":1.25}]}"#, timedOut: false)
            }
            return ToolResult(exitCode: 1, output: "", timedOut: false)
        }
        let reader = XCResultReader(environment: AppEnvironment(
            paths: AppPaths(stateRoot: temp.appendingPathComponent("state")),
            toolRunner: runner
        ))

        let summary = try XCTUnwrap(reader.summary(at: resultBundle))
        let timings = reader.testTimings(at: resultBundle)

        XCTAssertEqual(summary.testsCount, 1)
        XCTAssertEqual(timings.map(\.identifier), ["DemoTests/FooTests/testA"])
        XCTAssertTrue(commands.contains(["xcresulttool", "get", "test-results", "summary", "--path", resultBundle.path]))
        XCTAssertTrue(commands.contains(["xcresulttool", "get", "test-results", "tests", "--path", resultBundle.path]))
    }
}

private final class StubToolRunner: ToolRunning {
    private let handler: (String, [String]) -> ToolResult

    init(handler: @escaping (String, [String]) -> ToolResult) {
        self.handler = handler
    }

    func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)?
    ) throws -> ToolResult {
        handler(tool, arguments)
    }
}
