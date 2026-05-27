// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct SubmitCommandOptions {
    var request: JobRequest
    var waitTimeout: TimeInterval
    var json: Bool
    var progress: Bool

    static func parse(arguments inputArguments: [String]) throws -> SubmitCommandOptions {
        var arguments = inputArguments
        guard let project = try consumeOption("--project", from: &arguments) else {
            throw XCStewardError.usage("submit requires --project")
        }
        let wait = removeFlag("--wait", from: &arguments)
        let waitTimeout = try consumeOption("--wait-timeout", from: &arguments)
            .map(parseWaitTimeout(_:)) ?? 30
        let json = removeFlag("--json", from: &arguments)
        let progress = removeFlag("--progress", from: &arguments)
        let testPlan = try consumeOption("--test-plan", from: &arguments)
        let explicitSimulator = try consumeOption("--simulator-id", from: &arguments)
        let onlyTesting = try consumeRepeatedOption("--only-testing", from: &arguments)
        let skipTesting = try consumeRepeatedOption("--skip-testing", from: &arguments)
        let onlyTestConfigurations = try consumeRepeatedOption("--only-test-configuration", from: &arguments)
        let skipTestConfigurations = try consumeRepeatedOption("--skip-test-configuration", from: &arguments)
        guard arguments.isEmpty else {
            throw XCStewardError.usage("submit received unexpected arguments: \(arguments.joined(separator: " "))")
        }

        return SubmitCommandOptions(
            request: JobRequest(
                project: project,
                testPlan: testPlan,
                onlyTesting: onlyTesting,
                skipTesting: skipTesting,
                onlyTestConfigurations: onlyTestConfigurations,
                skipTestConfigurations: skipTestConfigurations,
                simulatorID: explicitSimulator,
                metadata: [:],
                wait: wait
            ),
            waitTimeout: waitTimeout,
            json: json,
            progress: progress
        )
    }

    private static func consumeRepeatedOption(_ option: String, from arguments: inout [String]) throws -> [String] {
        var values: [String] = []
        while let value = try consumeOption(option, from: &arguments) {
            values.append(value)
        }
        return values
    }

    private static func parseWaitTimeout(_ value: String) throws -> TimeInterval {
        guard let timeout = Double(value), timeout >= 1 else {
            throw XCStewardError.usage("submit --wait-timeout must be at least 1 second")
        }
        return timeout
    }
}
