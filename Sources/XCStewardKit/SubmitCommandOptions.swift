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
        let envOverrides = try parseEnvOverrides(entries: consumeRepeatedOption("--env", from: &arguments))
        let metadata = try parseMetadata(
            entries: consumeRepeatedOption("--metadata", from: &arguments),
            label: try consumeOption("--label", from: &arguments)
        )
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
                envOverrides: envOverrides,
                metadata: metadata,
                wait: wait
            ),
            waitTimeout: waitTimeout,
            json: json,
            progress: progress
        )
    }

    private static func parseMetadata(entries: [String], label: String?) throws -> [String: String] {
        var metadata: [String: String] = [:]
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw XCStewardError.usage("submit --metadata must be key=value")
            }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else {
                throw XCStewardError.usage("submit --metadata requires non-empty key and value")
            }
            guard key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw XCStewardError.usage("submit --metadata key must not contain whitespace")
            }
            guard metadata[key] == nil else {
                throw XCStewardError.usage("submit --metadata contains duplicate key '\(key)'")
            }
            metadata[key] = value
        }
        if let label {
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLabel.isEmpty else {
                throw XCStewardError.usage("submit --label requires a non-empty value")
            }
            guard metadata["label"] == nil else {
                throw XCStewardError.usage("submit --label conflicts with --metadata label=...")
            }
            metadata["label"] = trimmedLabel
        }
        return metadata
    }

    private static func parseEnvOverrides(entries: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw XCStewardError.usage("submit --env must be KEY=VALUE")
            }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else {
                throw XCStewardError.usage("submit --env requires non-empty key and value")
            }
            guard isValidEnvironmentKey(key) else {
                throw XCStewardError.usage("submit --env key must match [A-Za-z_][A-Za-z0-9_]*")
            }
            guard values[key] == nil else {
                throw XCStewardError.usage("submit --env contains duplicate key '\(key)'")
            }
            values[key] = value
        }
        return values
    }

    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else {
            return false
        }
        let firstSet = CharacterSet.letters.union(CharacterSet(charactersIn: "_"))
        let restSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        guard firstSet.contains(first) else {
            return false
        }
        return key.unicodeScalars.dropFirst().allSatisfy { restSet.contains($0) }
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
