import Foundation
import XCTest
@testable import XCStewardKit

final class XcodebuildCommandBuilderTests: XCTestCase {
    func testBuildForTestingIncludesTestPlanAndOmitsParallelFlags() {
        let profile = makeProfile(
            parallel: ParallelSettings(mode: .xcodeManaged, maxWorkers: 8, exactWorkers: true),
            testProducts: TestProductsSettings(enabled: true)
        )
        let request = makeRequest(testPlan: "Smoke")
        let paths = makePaths(request: request)

        let arguments = XcodebuildCommandBuilder(profile: profile).buildForTesting(
            simulatorID: "SIM-123",
            paths: paths,
            request: request
        )

        XCTAssertTrue(arguments.containsSequence(["-project", "/repo/App.xcodeproj", "-scheme", "Demo"]))
        XCTAssertTrue(arguments.containsSequence(["-destination", "id=SIM-123"]))
        XCTAssertTrue(arguments.containsSequence(["-derivedDataPath", paths.derivedData.path]))
        XCTAssertTrue(arguments.containsSequence(["-testPlan", "Smoke"]))
        XCTAssertTrue(arguments.containsSequence(["-testProductsPath", paths.testProducts.path]))
        XCTAssertFalse(arguments.contains("-parallel-testing-enabled"))
        XCTAssertFalse(arguments.contains("-parallel-testing-worker-count"))
        XCTAssertFalse(arguments.contains("-maximum-parallel-testing-workers"))
        XCTAssertEqual(arguments.last, "build-for-testing")
    }

    func testXcodeManagedTestUsesMaximumWorkersByDefault() {
        let profile = makeProfile(parallel: ParallelSettings(mode: .xcodeManaged, maxWorkers: 4, exactWorkers: false))
        let request = makeRequest(onlyTesting: ["DemoTests/FooTests"], skipTesting: ["DemoTests/SkipTests"])
        let paths = makePaths(request: request)

        let arguments = XcodebuildCommandBuilder(profile: profile).xcodeManagedTest(
            testReference: .xctestrun(URL(fileURLWithPath: "/tmp/Demo.xctestrun")),
            simulatorID: "SIM-123",
            paths: paths,
            request: request
        )

        XCTAssertTrue(arguments.containsSequence(["-parallel-testing-enabled", "YES"]))
        XCTAssertTrue(arguments.containsSequence(["-maximum-parallel-testing-workers", "4"]))
        XCTAssertFalse(arguments.contains("-parallel-testing-worker-count"))
        XCTAssertTrue(arguments.contains("-only-testing:DemoTests/FooTests"))
        XCTAssertTrue(arguments.contains("-skip-testing:DemoTests/SkipTests"))
        XCTAssertEqual(arguments.last, "test-without-building")
    }

    func testXcodeManagedTargetedMethodSerializesWorkerToAvoidCloneLaunches() {
        let profile = makeProfile(parallel: ParallelSettings(mode: .xcodeManaged, maxWorkers: 4, exactWorkers: false))
        let request = makeRequest(onlyTesting: ["DemoTests/FooTests/testA"])
        let paths = makePaths(request: request)

        let arguments = XcodebuildCommandBuilder(profile: profile).xcodeManagedTest(
            testReference: .xctestrun(URL(fileURLWithPath: "/tmp/Demo.xctestrun")),
            simulatorID: "SIM-123",
            paths: paths,
            request: request
        )

        XCTAssertTrue(arguments.containsSequence(["-parallel-testing-enabled", "NO"]))
        XCTAssertTrue(arguments.containsSequence(["-maximum-parallel-testing-workers", "1"]))
        XCTAssertFalse(arguments.contains("-parallel-testing-worker-count"))
    }

    func testDefaultXcodeManagedParallelismUsesSingleWorker() {
        let profile = makeProfile()
        let request = makeRequest()
        let paths = makePaths(request: request)

        let arguments = XcodebuildCommandBuilder(profile: profile).xcodeManagedTest(
            testReference: .xctestrun(URL(fileURLWithPath: "/tmp/Demo.xctestrun")),
            simulatorID: "SIM-123",
            paths: paths,
            request: request
        )

        XCTAssertTrue(arguments.containsSequence(["-parallel-testing-enabled", "NO"]))
        XCTAssertTrue(arguments.containsSequence(["-maximum-parallel-testing-workers", "1"]))
        XCTAssertFalse(arguments.contains("-parallel-testing-worker-count"))
    }

    func testXcodeManagedTestCanUseExactWorkerCount() {
        let profile = makeProfile(parallel: ParallelSettings(mode: .xcodeManaged, maxWorkers: 2, exactWorkers: true))
        let request = makeRequest()
        let paths = makePaths(request: request)

        let arguments = XcodebuildCommandBuilder(profile: profile).xcodeManagedTest(
            testReference: .xctestrun(URL(fileURLWithPath: "/tmp/Demo.xctestrun")),
            simulatorID: "SIM-123",
            paths: paths,
            request: request
        )

        XCTAssertTrue(arguments.containsSequence(["-parallel-testing-enabled", "YES"]))
        XCTAssertTrue(arguments.containsSequence(["-parallel-testing-worker-count", "2"]))
        XCTAssertFalse(arguments.contains("-maximum-parallel-testing-workers"))
    }

    func testSerialModeKeepsSingleWorkerFlags() {
        let profile = makeProfile(parallel: ParallelSettings(mode: .serial, maxWorkers: 9, exactWorkers: true))
        let request = makeRequest()
        let paths = makePaths(request: request)

        let arguments = XcodebuildCommandBuilder(profile: profile).xcodeManagedTest(
            testReference: .xctestrun(URL(fileURLWithPath: "/tmp/Demo.xctestrun")),
            simulatorID: "SIM-123",
            paths: paths,
            request: request
        )

        XCTAssertTrue(arguments.containsSequence(["-parallel-testing-enabled", "NO"]))
        XCTAssertTrue(arguments.containsSequence(["-maximum-parallel-testing-workers", "1"]))
        XCTAssertFalse(arguments.contains("-parallel-testing-worker-count"))
    }

    func testManualShardDisablesInnerParallelismAndHybridEnablesIt() {
        let shardResult = URL(fileURLWithPath: "/tmp/shard/result.xcresult")
        let shardStream = URL(fileURLWithPath: "/tmp/shard/result-stream.json")
        let testReference = TestProductReference.xctestrun(URL(fileURLWithPath: "/tmp/Demo.xctestrun"))
        let manualArguments = XcodebuildCommandBuilder(
            profile: makeProfile(parallel: ParallelSettings(mode: .manualShards, maxWorkers: 5, exactWorkers: true))
        ).manualShardTest(
            testReference: testReference,
            simulatorID: "SIM-1",
            resultBundle: shardResult,
            resultStream: shardStream,
            onlyTesting: ["DemoTests/A"],
            skipTesting: [],
            onlyTestConfigurations: [],
            skipTestConfigurations: []
        )
        let hybridArguments = XcodebuildCommandBuilder(
            profile: makeProfile(parallel: ParallelSettings(mode: .hybrid, maxWorkers: 3, exactWorkers: false))
        ).manualShardTest(
            testReference: testReference,
            simulatorID: "SIM-1",
            resultBundle: shardResult,
            resultStream: shardStream,
            onlyTesting: ["DemoTests/A"],
            skipTesting: [],
            onlyTestConfigurations: [],
            skipTestConfigurations: []
        )

        XCTAssertTrue(manualArguments.containsSequence(["-parallel-testing-enabled", "NO"]))
        XCTAssertTrue(manualArguments.containsSequence(["-maximum-parallel-testing-workers", "1"]))
        XCTAssertTrue(hybridArguments.containsSequence(["-parallel-testing-enabled", "YES"]))
        XCTAssertTrue(hybridArguments.containsSequence(["-maximum-parallel-testing-workers", "3"]))
    }

    func testTestWithoutBuildingCentralizesSharedArguments() {
        let profile = makeProfile(
            parallel: ParallelSettings(mode: .xcodeManaged, maxWorkers: 4),
            xctestRetries: XCTestRetrySettings(enabled: true, iterations: 2, retryTestsOnFailure: true),
            xctestDiagnostics: XCTestDiagnosticSettings(collect: .onFailure),
            resultStream: ResultStreamSettings(enabled: true),
            resultBundle: ResultBundleSettings(version: 3)
        )
        let request = makeRequest(
            onlyTesting: ["DemoTests/FooTests/testA"],
            skipTesting: ["DemoTests/SkipTests"],
            onlyTestConfigurations: ["Debug"],
            skipTestConfigurations: ["Release"]
        )
        let paths = makePaths(request: request)

        let arguments = XcodebuildCommandBuilder(profile: profile).xcodeManagedTest(
            testReference: .testProducts(URL(fileURLWithPath: "/tmp/Demo.xctestproducts")),
            simulatorID: "SIM-123",
            paths: paths,
            request: request
        )

        XCTAssertTrue(arguments.containsSequence(["-testProductsPath", "/tmp/Demo.xctestproducts"]))
        XCTAssertTrue(arguments.containsSequence(["-resultBundlePath", paths.resultBundle.path]))
        XCTAssertTrue(arguments.containsSequence(["-resultStreamPath", paths.resultStream.path]))
        XCTAssertTrue(arguments.containsSequence(["-resultBundleVersion", "3"]))
        XCTAssertTrue(arguments.containsSequence(["-destination-timeout", "90"]))
        XCTAssertTrue(arguments.containsSequence(["-enableCodeCoverage", "YES"]))
        XCTAssertTrue(arguments.containsSequence(["-test-timeouts-enabled", "YES"]))
        XCTAssertTrue(arguments.containsSequence(["-test-iterations", "2"]))
        XCTAssertTrue(arguments.contains("-retry-tests-on-failure"))
        XCTAssertTrue(arguments.containsSequence(["-collect-test-diagnostics", "on-failure"]))
        XCTAssertTrue(arguments.containsSequence(["-only-test-configuration", "Debug"]))
        XCTAssertTrue(arguments.containsSequence(["-skip-test-configuration", "Release"]))
    }

    func testEnumerationCommandKeepsOnlyEnumerationRelevantArguments() {
        let profile = makeProfile(
            parallel: ParallelSettings(mode: .xcodeManaged, maxWorkers: 4),
            resultStream: ResultStreamSettings(enabled: true),
            resultBundle: ResultBundleSettings(version: 3)
        )
        let output = URL(fileURLWithPath: "/tmp/tests.json")

        let arguments = XcodebuildCommandBuilder(profile: profile).enumerateTests(
            testReference: .xctestrun(URL(fileURLWithPath: "/tmp/Demo.xctestrun")),
            simulatorID: "SIM-123",
            outputPath: output,
            onlyTestConfigurations: ["Debug"],
            skipTestConfigurations: ["Release"]
        )

        XCTAssertTrue(arguments.containsSequence(["-xctestrun", "/tmp/Demo.xctestrun"]))
        XCTAssertTrue(arguments.containsSequence(["-destination", "id=SIM-123"]))
        XCTAssertTrue(arguments.containsSequence(["-destination-timeout", "90"]))
        XCTAssertTrue(arguments.containsSequence(["-only-test-configuration", "Debug"]))
        XCTAssertTrue(arguments.containsSequence(["-skip-test-configuration", "Release"]))
        XCTAssertTrue(arguments.containsSequence(["-test-enumeration-output-path", output.path]))
        XCTAssertFalse(arguments.contains("-resultBundlePath"))
        XCTAssertFalse(arguments.contains("-resultStreamPath"))
        XCTAssertFalse(arguments.contains("-parallel-testing-enabled"))
        XCTAssertEqual(arguments.last, "test-without-building")
    }
}

private func makeProfile(
    parallel: ParallelSettings = ParallelSettings(),
    xctestRetries: XCTestRetrySettings = XCTestRetrySettings(),
    xctestDiagnostics: XCTestDiagnosticSettings = XCTestDiagnosticSettings(),
    resultStream: ResultStreamSettings = ResultStreamSettings(),
    resultBundle: ResultBundleSettings = ResultBundleSettings(),
    testProducts: TestProductsSettings = TestProductsSettings()
) -> ProjectProfile {
    ProjectProfile(
        name: "demo",
        repoRoot: "/repo",
        projectPath: "App.xcodeproj",
        workspacePath: nil,
        scheme: "Demo",
        defaultSimulatorID: "SIM-123",
        managedSimulator: nil,
        defaultTestPlan: "DefaultPlan",
        allowedSimulatorIDs: [],
        env: [:],
        timeouts: Timeouts(),
        resetPolicy: nil,
        parallel: parallel,
        ports: nil,
        xctestTimeouts: XCTestTimeoutSettings(),
        xctestRetries: xctestRetries,
        xctestDiagnostics: xctestDiagnostics,
        destination: XcodeDestinationSettings(timeout: 90),
        coverage: CodeCoverageSettings(enabled: true),
        resultStream: resultStream,
        resultBundle: resultBundle,
        testProducts: testProducts,
        privacy: SimulatorPrivacySettings()
    )
}

private func makeRequest(
    testPlan: String? = nil,
    onlyTesting: [String] = [],
    skipTesting: [String] = [],
    onlyTestConfigurations: [String] = [],
    skipTestConfigurations: [String] = []
) -> JobRequest {
    JobRequest(
        project: "demo",
        testPlan: testPlan,
        onlyTesting: onlyTesting,
        skipTesting: skipTesting,
        onlyTestConfigurations: onlyTestConfigurations,
        skipTestConfigurations: skipTestConfigurations,
        simulatorID: nil,
        metadata: [:],
        wait: false
    )
}

private func makePaths(request: JobRequest) -> ExecutionPaths {
    ExecutionPaths(job: JobRecord(
        id: "job-123",
        project: "demo",
        state: .queued,
        resultClass: nil,
        request: request,
        summary: nil,
        jobDirectory: "/tmp/xcsteward-job",
        createdAt: 0,
        startedAt: nil,
        finishedAt: nil,
        processID: nil,
        simulatorID: nil,
        cancelRequested: false
    ))
}

private extension Array where Element == String {
    func containsSequence(_ expected: [String]) -> Bool {
        guard !expected.isEmpty, expected.count <= count else {
            return false
        }
        for index in 0...(count - expected.count) {
            if Array(self[index..<(index + expected.count)]) == expected {
                return true
            }
        }
        return false
    }
}
