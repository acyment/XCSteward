import Foundation

struct XcodebuildCommandBuilder {
    var profile: ProjectProfile

    func showDestinations() -> [String] {
        baseArguments() + ["-showdestinations"]
    }

    func buildForTesting(simulatorID: String, paths: ExecutionPaths, request: JobRequest) -> [String] {
        var arguments = baseArguments()
        arguments.append(contentsOf: [
            "-destination", "id=\(simulatorID)",
            "-derivedDataPath", paths.derivedData.path,
        ])
        arguments.append(contentsOf: destinationTimeoutArguments())
        arguments.append(contentsOf: codeCoverageArguments())
        if let testPlan = request.testPlan ?? profile.defaultTestPlan, !testPlan.isEmpty {
            arguments.append(contentsOf: ["-testPlan", testPlan])
        }
        if profile.testProducts.materializeDuringBuild {
            arguments.append(contentsOf: ["-testProductsPath", paths.testProducts.path])
        }
        arguments.append("build-for-testing")
        return arguments
    }

    func xcodeManagedTest(
        testReference: TestProductReference,
        simulatorID: String,
        paths: ExecutionPaths,
        request: JobRequest
    ) -> [String] {
        testWithoutBuilding(
            testReference: testReference,
            simulatorID: simulatorID,
            resultBundle: paths.resultBundle,
            resultStream: paths.resultStream,
            parallelArguments: parallelTestingArguments(for: profile.parallel, onlyTesting: request.onlyTesting),
            onlyTesting: request.onlyTesting,
            skipTesting: request.skipTesting,
            onlyTestConfigurations: request.onlyTestConfigurations,
            skipTestConfigurations: request.skipTestConfigurations
        )
    }

    func manualShardTest(
        testReference: TestProductReference,
        simulatorID: String,
        resultBundle: URL,
        resultStream: URL,
        onlyTesting: [String],
        skipTesting: [String],
        onlyTestConfigurations: [String],
        skipTestConfigurations: [String]
    ) -> [String] {
        testWithoutBuilding(
            testReference: testReference,
            simulatorID: simulatorID,
            resultBundle: resultBundle,
            resultStream: resultStream,
            parallelArguments: manualShardParallelTestingArguments(for: profile.parallel),
            onlyTesting: onlyTesting,
            skipTesting: skipTesting,
            onlyTestConfigurations: onlyTestConfigurations,
            skipTestConfigurations: skipTestConfigurations
        )
    }

    func enumerateTests(
        testReference: TestProductReference,
        simulatorID: String,
        outputPath: URL,
        onlyTestConfigurations: [String],
        skipTestConfigurations: [String]
    ) -> [String] {
        var arguments = testReference.arguments + [
            "-destination", "id=\(simulatorID)",
        ]
        arguments.append(contentsOf: destinationTimeoutArguments())
        arguments.append(contentsOf: testConfigurationArguments(
            only: onlyTestConfigurations,
            skip: skipTestConfigurations
        ))
        arguments.append(contentsOf: [
            "-enumerate-tests",
            "-test-enumeration-style", "flat",
            "-test-enumeration-format", "json",
            "-test-enumeration-output-path", outputPath.path,
            "test-without-building",
        ])
        return arguments
    }

    private func testWithoutBuilding(
        testReference: TestProductReference,
        simulatorID: String,
        resultBundle: URL,
        resultStream: URL,
        parallelArguments: [String],
        onlyTesting: [String],
        skipTesting: [String],
        onlyTestConfigurations: [String],
        skipTestConfigurations: [String]
    ) -> [String] {
        var arguments = testReference.arguments + [
            "-destination", "id=\(simulatorID)",
            "-resultBundlePath", resultBundle.path,
        ]
        arguments.append(contentsOf: resultStreamArguments(path: resultStream))
        arguments.append(contentsOf: resultBundleArguments())
        arguments.append(contentsOf: destinationTimeoutArguments())
        arguments.append(contentsOf: codeCoverageArguments())
        arguments.append(contentsOf: parallelArguments)
        arguments.append(contentsOf: xctestTimeoutArguments())
        arguments.append(contentsOf: xctestRetryArguments())
        arguments.append(contentsOf: xctestDiagnosticArguments())
        arguments.append(contentsOf: testConfigurationArguments(
            only: onlyTestConfigurations,
            skip: skipTestConfigurations
        ))
        for identifier in onlyTesting {
            arguments.append("-only-testing:\(identifier)")
        }
        arguments.append(contentsOf: skipTestingArguments(skipTesting))
        arguments.append("test-without-building")
        return arguments
    }

    private func baseArguments() -> [String] {
        if let projectPath = profile.projectPath {
            return ["-project", URL(fileURLWithPath: profile.repoRoot).appendingPathComponent(projectPath).path, "-scheme", profile.scheme]
        }
        if let workspacePath = profile.workspacePath {
            return ["-workspace", URL(fileURLWithPath: profile.repoRoot).appendingPathComponent(workspacePath).path, "-scheme", profile.scheme]
        }
        return ["-scheme", profile.scheme]
    }

    private func parallelTestingArguments(for settings: ParallelSettings, onlyTesting: [String] = []) -> [String] {
        if settings.maxWorkers <= 1 || shouldSerializeTargetedMethod(settings: settings, onlyTesting: onlyTesting) {
            return serialParallelTestingArguments()
        }
        switch settings.mode {
        case .serial, .manualShards:
            return serialParallelTestingArguments()
        case .xcodeManaged, .hybrid:
            if settings.exactWorkers {
                return [
                    "-parallel-testing-enabled", "YES",
                    "-parallel-testing-worker-count", "\(settings.maxWorkers)",
                ]
            }
            return [
                "-parallel-testing-enabled", "YES",
                "-maximum-parallel-testing-workers", "\(settings.maxWorkers)",
            ]
        }
    }

    private func serialParallelTestingArguments() -> [String] {
        [
            "-parallel-testing-enabled", "NO",
            "-maximum-parallel-testing-workers", "1",
        ]
    }

    private func shouldSerializeTargetedMethod(settings: ParallelSettings, onlyTesting: [String]) -> Bool {
        guard !settings.exactWorkers,
              settings.maxWorkers > 1,
              onlyTesting.count == 1 else {
            return false
        }
        switch settings.mode {
        case .xcodeManaged, .hybrid:
            return onlyTesting[0].split(separator: "/").count >= 3
        case .serial, .manualShards:
            return false
        }
    }

    private func manualShardParallelTestingArguments(for settings: ParallelSettings) -> [String] {
        switch settings.mode {
        case .hybrid:
            return parallelTestingArguments(for: ParallelSettings(
                mode: .xcodeManaged,
                maxWorkers: settings.maxWorkers,
                exactWorkers: settings.exactWorkers,
                shardCount: settings.shardCount
            ))
        case .manualShards, .serial, .xcodeManaged:
            return parallelTestingArguments(for: ParallelSettings(
                mode: .serial,
                maxWorkers: 1,
                exactWorkers: false,
                shardCount: 1
            ))
        }
    }

    private func xctestTimeoutArguments() -> [String] {
        let settings = profile.xctestTimeouts
        guard settings.enabled else {
            return ["-test-timeouts-enabled", "NO"]
        }
        return [
            "-test-timeouts-enabled", "YES",
            "-default-test-execution-time-allowance", "\(settings.defaultExecutionTimeAllowance)",
            "-maximum-test-execution-time-allowance", "\(settings.maximumExecutionTimeAllowance)",
        ]
    }

    private func xctestRetryArguments() -> [String] {
        let settings = profile.xctestRetries
        guard settings.enabled else {
            return []
        }
        var arguments = ["-test-iterations", "\(settings.iterations)"]
        if settings.runTestsUntilFailure {
            arguments.append("-run-tests-until-failure")
        } else if settings.retryTestsOnFailure {
            arguments.append("-retry-tests-on-failure")
        }
        if let relaunchBetweenIterations = settings.relaunchBetweenIterations {
            arguments.append(contentsOf: [
                "-test-repetition-relaunch-enabled",
                relaunchBetweenIterations ? "YES" : "NO",
            ])
        }
        return arguments
    }

    private func xctestDiagnosticArguments() -> [String] {
        guard let collect = profile.xctestDiagnostics.collect else {
            return []
        }
        return ["-collect-test-diagnostics", collect.rawValue]
    }

    private func skipTestingArguments(_ identifiers: [String]) -> [String] {
        identifiers.map { "-skip-testing:\($0)" }
    }

    private func testConfigurationArguments(only: [String], skip: [String]) -> [String] {
        var arguments: [String] = []
        for configuration in only {
            arguments.append(contentsOf: ["-only-test-configuration", configuration])
        }
        for configuration in skip {
            arguments.append(contentsOf: ["-skip-test-configuration", configuration])
        }
        return arguments
    }

    private func destinationTimeoutArguments() -> [String] {
        guard let timeout = profile.destination.timeout else {
            return []
        }
        return ["-destination-timeout", "\(timeout)"]
    }

    private func codeCoverageArguments() -> [String] {
        guard let enabled = profile.coverage.enabled else {
            return []
        }
        return ["-enableCodeCoverage", enabled ? "YES" : "NO"]
    }

    private func resultStreamArguments(path: URL) -> [String] {
        guard profile.resultStream.enabled else {
            return []
        }
        return ["-resultStreamPath", path.path]
    }

    private func resultBundleArguments() -> [String] {
        guard let version = profile.resultBundle.version else {
            return []
        }
        return ["-resultBundleVersion", "\(version)"]
    }
}
