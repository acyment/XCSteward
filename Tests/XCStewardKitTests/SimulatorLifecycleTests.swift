// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCTest
@testable import XCStewardKit

final class SimulatorLifecycleTests: XCTestCase {
    func testAlreadyBootedSimulatorIsShutdownAndRebootedWhenBootstatusFails() throws {
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile())
        fixture.tooling.results = [
            ToolResult(exitCode: 1, output: "Unable to boot device in current state: Booted", timedOut: false),
            ToolResult(exitCode: 65, output: "bootstatus failed", timedOut: false),
            ToolResult(exitCode: 0, output: "", timedOut: false),
            ToolResult(exitCode: 0, output: "", timedOut: false),
            ToolResult(exitCode: 0, output: "", timedOut: false),
        ]

        try fixture.lifecycle.bootSimulator(simulatorID: "SIM-123", context: fixture.context)

        XCTAssertEqual(fixture.tooling.commands, [
            "xcrun simctl boot SIM-123",
            "xcrun simctl bootstatus SIM-123 -b",
            "xcrun simctl shutdown SIM-123",
            "xcrun simctl boot SIM-123",
            "xcrun simctl bootstatus SIM-123 -b",
        ])
    }

    func testAlreadyBootedStateParserToleratesCaseAndSpacing() throws {
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile())
        fixture.tooling.results = [
            ToolResult(exitCode: 1, output: "Unable to boot device; CURRENT STATE :   booted.", timedOut: false),
            ToolResult(exitCode: 65, output: "bootstatus failed", timedOut: false),
            ToolResult(exitCode: 0, output: "", timedOut: false),
            ToolResult(exitCode: 0, output: "", timedOut: false),
            ToolResult(exitCode: 0, output: "", timedOut: false),
        ]

        try fixture.lifecycle.bootSimulator(simulatorID: "SIM-123", context: fixture.context)

        XCTAssertEqual(fixture.tooling.commands, [
            "xcrun simctl boot SIM-123",
            "xcrun simctl bootstatus SIM-123 -b",
            "xcrun simctl shutdown SIM-123",
            "xcrun simctl boot SIM-123",
            "xcrun simctl bootstatus SIM-123 -b",
        ])
    }

    func testBootstatusFailureThrowsClearError() throws {
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile())
        fixture.tooling.results = [
            ToolResult(exitCode: 0, output: "", timedOut: false),
            ToolResult(exitCode: 65, output: "launchd_sim failed", timedOut: false),
        ]

        XCTAssertThrowsError(try fixture.lifecycle.bootSimulator(simulatorID: "SIM-123", context: fixture.context)) { error in
            XCTAssertTrue(String(describing: error).contains("Unable to confirm simulator boot status for SIM-123: launchd_sim failed"))
        }
    }

    func testAlreadyShutdownStateParserToleratesCaseAndSpacing() throws {
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile())
        fixture.tooling.results = [
            ToolResult(exitCode: 1, output: "Ignoring request because Current State :   shutdown.", timedOut: false),
        ]

        XCTAssertNoThrow(try fixture.lifecycle.shutdownSimulatorForCloneTemplate(
            simulatorID: "SIM-123",
            context: fixture.context
        ))
    }

    func testDefaultSimulatorIDIsValidatedBeforeUse() throws {
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile())
        fixture.tooling.results = [
            ToolResult(
                exitCode: 0,
                output: """
                {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"iPhone 17 Pro","udid":"SIM-123","state":"Shutdown","isAvailable":true}]}}
                """,
                timedOut: false
            ),
        ]

        let simulatorID = try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )

        XCTAssertEqual(simulatorID, "SIM-123")
        XCTAssertEqual(fixture.tooling.commands, [
            "xcrun simctl list devices --json",
        ])
    }

    func testMissingDefaultSimulatorIDFailsBeforeMutation() throws {
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile(defaultSimulatorID: "SIM-MISSING"))
        fixture.tooling.results = [
            ToolResult(
                exitCode: 0,
                output: """
                {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"iPhone 17 Pro","udid":"SIM-123","state":"Shutdown","isAvailable":true}]}}
                """,
                timedOut: false
            ),
        ]

        XCTAssertThrowsError(try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )) { error in
            let description = String(describing: error)
            XCTAssertTrue(description.contains("Configured simulator SIM-MISSING"))
            XCTAssertTrue(description.contains("refusing to fall back"))
        }
        XCTAssertEqual(fixture.tooling.commands, [
            "xcrun simctl list devices --json",
        ])
    }

    func testUnavailableDefaultSimulatorIDFailsBeforeMutation() throws {
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile(defaultSimulatorID: "SIM-OLD"))
        fixture.tooling.results = [
            ToolResult(
                exitCode: 0,
                output: """
                {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"Old iPhone","udid":"SIM-OLD","state":"Shutdown","isAvailable":false,"availabilityError":"runtime is unavailable"}]}}
                """,
                timedOut: false
            ),
        ]

        XCTAssertThrowsError(try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )) { error in
            let description = String(describing: error)
            XCTAssertTrue(description.contains("Configured simulator SIM-OLD"))
            XCTAssertTrue(description.contains("is unavailable"))
            XCTAssertTrue(description.contains("refusing to mutate simulator state"))
        }
        XCTAssertEqual(fixture.tooling.commands, [
            "xcrun simctl list devices --json",
        ])
    }

    func testManagedSimulatorCreateOutputRequiresSingleUDID() throws {
        let managed = ManagedSimulator(
            name: "XCSteward Managed",
            deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            cloneForShards: false
        )
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile(defaultSimulatorID: nil, managedSimulator: managed))
        fixture.tooling.results = [
            ToolResult(exitCode: 0, output: #"{"devices":{}}"#, timedOut: false),
            ToolResult(exitCode: 0, output: "created simulator\n00000000-0000-0000-0000-000000000123\n", timedOut: false),
        ]

        XCTAssertThrowsError(try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )) { error in
            XCTAssertTrue(String(describing: error).contains("expected a single simulator UDID"))
        }
    }

    func testManagedSimulatorCreateResolvesDisplayNamesToIdentifiers() throws {
        let managed = ManagedSimulator(
            name: "XCSteward Managed",
            deviceType: "iPhone 17 Pro",
            runtime: "iOS 18.0",
            cloneForShards: false
        )
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile(defaultSimulatorID: nil, managedSimulator: managed))
        fixture.tooling.results = [
            ToolResult(exitCode: 0, output: #"{"devices":{}}"#, timedOut: false),
            ToolResult(
                exitCode: 0,
                output: #"{"devicetypes":[{"identifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","name":"iPhone 17 Pro"}]}"#,
                timedOut: false
            ),
            ToolResult(
                exitCode: 0,
                output: #"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-0","name":"iOS 18.0","isAvailable":true}]}"#,
                timedOut: false
            ),
            ToolResult(exitCode: 0, output: "00000000-0000-0000-0000-000000000123\n", timedOut: false),
        ]

        let simulatorID = try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )

        XCTAssertEqual(simulatorID, "00000000-0000-0000-0000-000000000123")
        XCTAssertEqual(fixture.tooling.commands, [
            "xcrun simctl list devices --json",
            "xcrun simctl list devicetypes --json",
            "xcrun simctl list runtimes --json",
            "xcrun simctl create XCSteward Managed com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-18-0",
        ])
    }

    func testManagedSimulatorDiscoveryUsesJSONNameAndUDID() throws {
        let managed = ManagedSimulator(
            name: "XCSteward Managed",
            deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
            runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-0",
            cloneForShards: false
        )
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile(defaultSimulatorID: nil, managedSimulator: managed))
        fixture.tooling.results = [
            ToolResult(
                exitCode: 0,
                output: """
                {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"XCSteward Managed","udid":"SIM-123","state":"Shutdown","isAvailable":true}]}}
                """,
                timedOut: false
            ),
        ]

        let simulatorID = try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )

        XCTAssertEqual(simulatorID, "SIM-123")
        XCTAssertEqual(fixture.tooling.commands, [
            "xcrun simctl list devices --json",
        ])
    }

    func testManagedSimulatorDiscoverySkipsUnavailableDevicesAndPrefersRuntimeMatch() throws {
        let managed = ManagedSimulator(
            name: "XCSteward Managed",
            deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
            runtime: "iOS 18.0",
            cloneForShards: false
        )
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile(defaultSimulatorID: nil, managedSimulator: managed))
        fixture.tooling.results = [
            ToolResult(
                exitCode: 0,
                output: """
                {"devices":{
                  "com.apple.CoreSimulator.SimRuntime.iOS-17-4":[
                    {"name":"XCSteward Managed","udid":"SIM-OLD","state":"Shutdown","isAvailable":true}
                  ],
                  "com.apple.CoreSimulator.SimRuntime.iOS-18-0":[
                    {"name":"XCSteward Managed","udid":"SIM-BROKEN","state":"Shutdown","isAvailable":false,"availabilityError":"runtime is unavailable"},
                    {"name":"XCSteward Managed","udid":"SIM-NEW","state":"Shutdown","isAvailable":true}
                  ]
                }}
                """,
                timedOut: false
            ),
        ]

        let simulatorID = try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )

        XCTAssertEqual(simulatorID, "SIM-NEW")
    }

    func testManagedSimulatorDiscoveryMatchesCaseVariedRuntimePrefix() throws {
        let managed = ManagedSimulator(
            name: "XCSteward Managed",
            deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
            runtime: "iOS 18.0",
            cloneForShards: false
        )
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile(defaultSimulatorID: nil, managedSimulator: managed))
        fixture.tooling.results = [
            ToolResult(
                exitCode: 0,
                output: """
                {"devices":{
                  "COM.APPLE.CORESIMULATOR.SIMRUNTIME.IOS-17-4":[
                    {"name":"XCSteward Managed","udid":"SIM-OLD","state":"Shutdown","isAvailable":true}
                  ],
                  "COM.APPLE.CORESIMULATOR.SIMRUNTIME.IOS-18-0":[
                    {"name":"XCSteward Managed","udid":"SIM-NEW","state":"Shutdown","isAvailable":true}
                  ]
                }}
                """,
                timedOut: false
            ),
        ]

        let simulatorID = try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )

        XCTAssertEqual(simulatorID, "SIM-NEW")
    }

    func testManagedSimulatorDiscoverySkipsMismatchedDeviceTypeIdentifier() throws {
        let managed = ManagedSimulator(
            name: "XCSteward Managed",
            deviceType: "iPhone 17 Pro",
            runtime: "iOS 18.0",
            cloneForShards: false
        )
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile(defaultSimulatorID: nil, managedSimulator: managed))
        fixture.tooling.results = [
            ToolResult(
                exitCode: 0,
                output: """
                {"devices":{
                  "com.apple.CoreSimulator.SimRuntime.iOS-18-0":[
                    {"name":"XCSteward Managed","udid":"SIM-WRONG","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-16"},
                    {"name":"XCSteward Managed","udid":"SIM-RIGHT","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"}
                  ]
                }}
                """,
                timedOut: false
            ),
        ]

        let simulatorID = try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )

        XCTAssertEqual(simulatorID, "SIM-RIGHT")
    }

    func testManagedSimulatorDiscoveryKeepsOlderDeviceEntriesWithoutTypeIdentifier() throws {
        let managed = ManagedSimulator(
            name: "XCSteward Managed",
            deviceType: "iPhone 17 Pro",
            runtime: "iOS 18.0",
            cloneForShards: false
        )
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile(defaultSimulatorID: nil, managedSimulator: managed))
        fixture.tooling.results = [
            ToolResult(
                exitCode: 0,
                output: """
                {"devices":{
                  "com.apple.CoreSimulator.SimRuntime.iOS-18-0":[
                    {"name":"XCSteward Managed","udid":"SIM-OLD-SHAPE","state":"Shutdown","isAvailable":true}
                  ]
                }}
                """,
                timedOut: false
            ),
        ]

        let simulatorID = try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )

        XCTAssertEqual(simulatorID, "SIM-OLD-SHAPE")
    }

    func testManagedSimulatorDiscoveryHandlesTextualAvailabilityFields() throws {
        let managed = ManagedSimulator(
            name: "XCSteward Managed",
            deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-16",
            runtime: "iOS 18.0",
            cloneForShards: false
        )
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile(defaultSimulatorID: nil, managedSimulator: managed))
        fixture.tooling.results = [
            ToolResult(
                exitCode: 0,
                output: """
                {"devices":{
                  "com.apple.CoreSimulator.SimRuntime.iOS-18-0":[
                    {"name":"XCSteward Managed","udid":"SIM-TEXT-BROKEN","state":"Shutdown","availability":"not available (runtime profile not found)"},
                    {"name":"XCSteward Managed","udid":"SIM-SNAKE-BROKEN","state":"Shutdown","availability_error":"runtime is unavailable"},
                    {"name":"XCSteward Managed","udid":"SIM-FLAG-BROKEN","state":"Shutdown","isAvailable":"not available"},
                    {"name":"XCSteward Managed","udid":"SIM-TEXT-OK","state":"Shutdown","isAvailable":"YES"}
                  ]
                }}
                """,
                timedOut: false
            ),
        ]

        let simulatorID = try fixture.lifecycle.resolveSimulatorID(
            request: lifecycleRequest(),
            context: fixture.context
        )

        XCTAssertEqual(simulatorID, "SIM-TEXT-OK")
    }

    func testCloneCleanupShutsDownAndDeletesTransientSimulator() throws {
        let fixture = try makeLifecycleFixture(profile: lifecycleProfile())
        fixture.tooling.results = [
            ToolResult(exitCode: 0, output: "", timedOut: false),
            ToolResult(exitCode: 0, output: "", timedOut: false),
        ]

        fixture.lifecycle.deleteTransientSimulatorAfterJob(simulatorID: "SIM-TRANSIENT", context: fixture.context)

        XCTAssertEqual(fixture.tooling.commands, [
            "xcrun simctl shutdown SIM-TRANSIENT",
            "xcrun simctl delete SIM-TRANSIENT",
        ])
    }

    func testPrivacySetupRunsConfiguredSimctlPrivacyCommandsAndLogs() throws {
        let temp = try makeTempDirectory()
        let profile = lifecycleProfile(privacy: SimulatorPrivacySettings(permissions: [
            SimulatorPrivacyPermission(action: .grant, service: "photos", bundleIdentifier: "com.example.app"),
        ]))
        let fixture = try makeLifecycleFixture(profile: profile, temp: temp)
        fixture.tooling.results = [
            ToolResult(exitCode: 0, output: "", timedOut: false),
        ]
        let log = temp.appendingPathComponent("test.log")
        let combined = temp.appendingPathComponent("combined.log")

        try fixture.lifecycle.preparePrivacy(
            simulatorID: "SIM-123",
            logURL: log,
            combinedLog: combined,
            context: fixture.context
        )

        XCTAssertEqual(fixture.tooling.commands, [
            "xcrun simctl privacy SIM-123 grant photos com.example.app",
        ])
        XCTAssertTrue(try String(contentsOf: log).contains("Configured simulator privacy for SIM-123: grant photos com.example.app"))
        XCTAssertTrue(try String(contentsOf: combined).contains("Configured simulator privacy for SIM-123: grant photos com.example.app"))
    }
}

private struct LifecycleFixture {
    var lifecycle: SimulatorLifecycle
    var tooling: FakeSimulatorLifecycleTooling
    var context: ToolExecutionContext
}

private final class FakeSimulatorLifecycleTooling: SimulatorLifecycleTooling {
    var results: [ToolResult] = []
    var commands: [String] = []

    func runTool(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        environmentOverrides: [String: String]
    ) throws -> ToolResult {
        commands.append(([tool] + arguments).joined(separator: " "))
        guard !results.isEmpty else {
            return ToolResult(exitCode: 0, output: "", timedOut: false)
        }
        return results.removeFirst()
    }

    func throwIfCanceled(_ result: ToolResult, context: ToolExecutionContext) throws {}

    func commandFailed(_ message: String, output: String) -> XCStewardError {
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .commandFailed(detail.isEmpty ? message : "\(message): \(detail)")
    }

    func failAndLog(message: String, exitCode: Int32, logURL: URL, combinedLog: URL) throws -> ToolResult {
        try Data("\(message)\n".utf8).write(to: logURL)
        try Data("\(message)\n".utf8).write(to: combinedLog)
        return ToolResult(exitCode: exitCode, output: message, timedOut: false)
    }
}

private func makeLifecycleFixture(
    profile: ProjectProfile,
    temp: URL? = nil
) throws -> LifecycleFixture {
    let temp = try temp ?? makeTempDirectory()
    let environment = AppEnvironment(paths: AppPaths(stateRoot: temp.appendingPathComponent("state")))
    let store = try StateStore(environment: environment)
    let tooling = FakeSimulatorLifecycleTooling()
    return LifecycleFixture(
        lifecycle: SimulatorLifecycle(environment: environment, tooling: tooling),
        tooling: tooling,
        context: ToolExecutionContext(profile: profile, jobID: "job-123", store: store)
    )
}

private func lifecycleRequest(simulatorID: String? = nil) -> JobRequest {
    JobRequest(
        project: "demo",
        testPlan: nil,
        onlyTesting: [],
        simulatorID: simulatorID,
        metadata: [:],
        wait: false
    )
}

private func lifecycleProfile(
    defaultSimulatorID: String? = "SIM-123",
    managedSimulator: ManagedSimulator? = nil,
    privacy: SimulatorPrivacySettings = SimulatorPrivacySettings()
) -> ProjectProfile {
    ProjectProfile(
        name: "demo",
        repoRoot: "/tmp/demo",
        projectPath: "App.xcodeproj",
        workspacePath: nil,
        scheme: "Demo",
        defaultSimulatorID: defaultSimulatorID,
        managedSimulator: managedSimulator,
        defaultTestPlan: nil,
        allowedSimulatorIDs: [],
        env: [:],
        timeouts: Timeouts(boot: 3, build: 3, test: 3),
        resetPolicy: nil,
        parallel: ParallelSettings(),
        ports: nil,
        xctestTimeouts: XCTestTimeoutSettings(),
        xctestRetries: XCTestRetrySettings(),
        xctestDiagnostics: XCTestDiagnosticSettings(),
        destination: XcodeDestinationSettings(),
        coverage: CodeCoverageSettings(),
        resultStream: ResultStreamSettings(),
        resultBundle: ResultBundleSettings(),
        testProducts: TestProductsSettings(),
        privacy: privacy
    )
}
