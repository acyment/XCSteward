// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct TOMLProfileReader {
    private let raw: [String: [String: TOMLValue]]

    init(raw: [String: [String: TOMLValue]]) {
        self.raw = raw
    }

    var root: TOMLSectionReader {
        section("")
    }

    func section(_ name: String) -> TOMLSectionReader {
        TOMLSectionReader(values: raw[name] ?? [:])
    }
}

struct TOMLSectionReader {
    let values: [String: TOMLValue]

    var isEmpty: Bool {
        values.isEmpty
    }

    func string(_ key: String) -> String? {
        guard let value = values[key] else { return nil }
        if case let .string(string) = value { return string }
        return nil
    }

    func array(_ key: String) -> [String] {
        guard let value = values[key] else { return [] }
        if case let .array(values) = value { return values }
        return []
    }

    func integer(_ key: String) -> Int? {
        guard let value = values[key] else { return nil }
        if case let .integer(number) = value { return number }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        guard let value = values[key] else { return nil }
        if case let .bool(boolean) = value { return boolean }
        return nil
    }

}

enum ProfileSectionDecoders {
    static func parallel(profileName: String, reader: TOMLSectionReader) throws -> ParallelSettings {
        try validateKnownKeys(
            profileName: profileName,
            section: "parallel",
            reader: reader,
            allowedKeys: ["mode", "max_workers", "exact_workers", "shard_count"]
        )
        let parallelModeRaw = try optionalEnumString(
            profileName: profileName,
            keyPath: "parallel.mode",
            reader: reader,
            key: "mode"
        ) ?? ParallelMode.xcodeManaged.rawValue
        guard let parallelMode = ParallelMode(rawValue: parallelModeRaw) else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) has unsupported parallel.mode '\(parallelModeRaw)'")
        }
        let maxWorkers = try optionalInteger(
            profileName: profileName,
            keyPath: "parallel.max_workers",
            reader: reader,
            key: "max_workers"
        ) ?? 1
        guard maxWorkers >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) parallel.max_workers must be >= 1")
        }
        let shardCount = try optionalInteger(
            profileName: profileName,
            keyPath: "parallel.shard_count",
            reader: reader,
            key: "shard_count"
        ) ?? 1
        guard shardCount >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) parallel.shard_count must be >= 1")
        }
        return ParallelSettings(
            mode: parallelMode,
            maxWorkers: maxWorkers,
            exactWorkers: try optionalBool(
                profileName: profileName,
                keyPath: "parallel.exact_workers",
                reader: reader,
                key: "exact_workers"
            ) ?? false,
            shardCount: shardCount
        )
    }

    static func ports(
        profileName: String,
        reader: TOMLSectionReader,
        shardCount: Int
    ) throws -> PortRangeSettings? {
        guard !reader.isEmpty else {
            return nil
        }
        try validateKnownKeys(
            profileName: profileName,
            section: "ports",
            reader: reader,
            allowedKeys: ["base", "count", "stride"]
        )
        let base = try requiredInteger(profileName: profileName, section: "ports", key: "base", reader: reader)
        let count = try optionalInteger(
            profileName: profileName,
            keyPath: "ports.count",
            reader: reader,
            key: "count"
        ) ?? 16
        let stride = try optionalInteger(
            profileName: profileName,
            keyPath: "ports.stride",
            reader: reader,
            key: "stride"
        ) ?? 100
        guard (1...65535).contains(base) else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) ports.base must be between 1 and 65535")
        }
        guard count >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) ports.count must be >= 1")
        }
        guard stride >= count else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) ports.stride must be >= ports.count")
        }
        let lastShardIndex = max(shardCount - 1, 0)
        let highestPort = base + (lastShardIndex * stride) + count - 1
        guard highestPort <= 65535 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) ports range exceeds 65535 for configured shard_count")
        }
        return PortRangeSettings(base: base, count: count, stride: stride)
    }

    static func xctestTimeouts(profileName: String, reader: TOMLSectionReader) throws -> XCTestTimeoutSettings {
        try validateKnownKeys(
            profileName: profileName,
            section: "test_timeouts",
            reader: reader,
            allowedKeys: ["enabled", "default_execution_time_allowance", "maximum_execution_time_allowance"]
        )
        let enabled = try optionalBool(
            profileName: profileName,
            keyPath: "test_timeouts.enabled",
            reader: reader,
            key: "enabled"
        ) ?? true
        let defaultAllowance = try optionalInteger(
            profileName: profileName,
            keyPath: "test_timeouts.default_execution_time_allowance",
            reader: reader,
            key: "default_execution_time_allowance"
        ) ?? 120
        let maximumAllowance = try optionalInteger(
            profileName: profileName,
            keyPath: "test_timeouts.maximum_execution_time_allowance",
            reader: reader,
            key: "maximum_execution_time_allowance"
        ) ?? 600
        guard defaultAllowance >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_timeouts.default_execution_time_allowance must be >= 1")
        }
        guard maximumAllowance >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_timeouts.maximum_execution_time_allowance must be >= 1")
        }
        guard maximumAllowance >= defaultAllowance else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_timeouts.maximum_execution_time_allowance must be >= default_execution_time_allowance")
        }
        return XCTestTimeoutSettings(
            enabled: enabled,
            defaultExecutionTimeAllowance: defaultAllowance,
            maximumExecutionTimeAllowance: maximumAllowance
        )
    }

    static func xctestRetries(profileName: String, reader: TOMLSectionReader) throws -> XCTestRetrySettings {
        try validateKnownKeys(
            profileName: profileName,
            section: "test_retries",
            reader: reader,
            allowedKeys: ["enabled", "iterations", "retry_tests_on_failure", "run_tests_until_failure", "relaunch_between_iterations"]
        )
        let enabled = try optionalBool(
            profileName: profileName,
            keyPath: "test_retries.enabled",
            reader: reader,
            key: "enabled"
        ) ?? false
        let iterations = try optionalInteger(
            profileName: profileName,
            keyPath: "test_retries.iterations",
            reader: reader,
            key: "iterations"
        ) ?? 1
        let retryTestsOnFailure = try optionalBool(
            profileName: profileName,
            keyPath: "test_retries.retry_tests_on_failure",
            reader: reader,
            key: "retry_tests_on_failure"
        ) ?? true
        let runTestsUntilFailure = try optionalBool(
            profileName: profileName,
            keyPath: "test_retries.run_tests_until_failure",
            reader: reader,
            key: "run_tests_until_failure"
        ) ?? false
        let relaunchBetweenIterations = try optionalBool(
            profileName: profileName,
            keyPath: "test_retries.relaunch_between_iterations",
            reader: reader,
            key: "relaunch_between_iterations"
        )
        guard iterations >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_retries.iterations must be >= 1")
        }
        if enabled {
            guard iterations >= 2 else {
                throw XCStewardError.invalidConfiguration("Profile \(profileName) test_retries.iterations must be >= 2 when enabled")
            }
            guard retryTestsOnFailure != runTestsUntilFailure else {
                throw XCStewardError.invalidConfiguration("Profile \(profileName) test_retries.retry_tests_on_failure and run_tests_until_failure are mutually exclusive")
            }
        } else if relaunchBetweenIterations == true {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_retries.relaunch_between_iterations requires enabled = true")
        }
        return XCTestRetrySettings(
            enabled: enabled,
            iterations: iterations,
            retryTestsOnFailure: retryTestsOnFailure,
            runTestsUntilFailure: runTestsUntilFailure,
            relaunchBetweenIterations: relaunchBetweenIterations
        )
    }

    static func xctestDiagnostics(profileName: String, reader: TOMLSectionReader) throws -> XCTestDiagnosticSettings {
        guard !reader.isEmpty else {
            return XCTestDiagnosticSettings()
        }
        try validateKnownKeys(
            profileName: profileName,
            section: "test_diagnostics",
            reader: reader,
            allowedKeys: ["collect"]
        )
        guard let collectRaw = try optionalEnumString(
            profileName: profileName,
            keyPath: "test_diagnostics.collect",
            reader: reader,
            key: "collect"
        ) else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_diagnostics.collect is required when [test_diagnostics] is present")
        }
        guard let collect = XCTestDiagnosticCollectionMode(rawValue: collectRaw) else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_diagnostics.collect must be 'on-failure' or 'never'")
        }
        return XCTestDiagnosticSettings(collect: collect)
    }

    static func destination(profileName: String, reader: TOMLSectionReader) throws -> XcodeDestinationSettings {
        try validateKnownKeys(
            profileName: profileName,
            section: "destination",
            reader: reader,
            allowedKeys: ["timeout"]
        )
        guard let timeout = try optionalInteger(
            profileName: profileName,
            keyPath: "destination.timeout",
            reader: reader,
            key: "timeout"
        ) else {
            return XcodeDestinationSettings()
        }
        guard timeout >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) destination.timeout must be >= 1")
        }
        return XcodeDestinationSettings(timeout: timeout)
    }

    static func coverage(profileName: String, reader: TOMLSectionReader) throws -> CodeCoverageSettings {
        guard !reader.isEmpty else {
            return CodeCoverageSettings()
        }
        try validateKnownKeys(
            profileName: profileName,
            section: "coverage",
            reader: reader,
            allowedKeys: ["enabled"]
        )
        let enabled = try requiredBool(profileName: profileName, section: "coverage", key: "enabled", reader: reader)
        return CodeCoverageSettings(enabled: enabled)
    }

    static func resultStream(profileName: String, reader: TOMLSectionReader) throws -> ResultStreamSettings {
        guard !reader.isEmpty else {
            return ResultStreamSettings()
        }
        try validateKnownKeys(
            profileName: profileName,
            section: "result_stream",
            reader: reader,
            allowedKeys: ["enabled"]
        )
        let enabled = try requiredBool(profileName: profileName, section: "result_stream", key: "enabled", reader: reader)
        return ResultStreamSettings(enabled: enabled)
    }

    static func resultBundle(profileName: String, reader: TOMLSectionReader) throws -> ResultBundleSettings {
        guard !reader.isEmpty else {
            return ResultBundleSettings()
        }
        try validateKnownKeys(
            profileName: profileName,
            section: "result_bundle",
            reader: reader,
            allowedKeys: ["version"]
        )
        let version = try requiredInteger(profileName: profileName, section: "result_bundle", key: "version", reader: reader)
        guard version >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) result_bundle.version must be >= 1")
        }
        return ResultBundleSettings(version: version)
    }

    static func testProducts(profileName: String, reader: TOMLSectionReader) throws -> TestProductsSettings {
        guard !reader.isEmpty else {
            return TestProductsSettings()
        }
        try validateKnownKeys(
            profileName: profileName,
            section: "test_products",
            reader: reader,
            allowedKeys: ["enabled", "use_for_testing"]
        )
        let enabled = try optionalBool(profileName: profileName, section: "test_products", key: "enabled", reader: reader) ?? false
        let useForTesting = try optionalBool(profileName: profileName, section: "test_products", key: "use_for_testing", reader: reader) ?? false
        if useForTesting && !enabled {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_products.use_for_testing requires enabled = true")
        }
        return TestProductsSettings(enabled: enabled, useForTesting: useForTesting)
    }

    static func privacy(profileName: String, reader: TOMLSectionReader) throws -> SimulatorPrivacySettings {
        guard !reader.isEmpty else {
            return SimulatorPrivacySettings()
        }
        try validateKnownKeys(
            profileName: profileName,
            section: "privacy",
            reader: reader,
            allowedKeys: ["grant", "reset", "revoke"]
        )
        var permissions: [SimulatorPrivacyPermission] = []
        for entry in try stringArray(profileName: profileName, section: "privacy", key: "grant", reader: reader) {
            permissions.append(try simulatorPrivacyPermission(
                profileName: profileName,
                action: .grant,
                rawEntry: entry
            ))
        }
        for entry in try stringArray(profileName: profileName, section: "privacy", key: "revoke", reader: reader) {
            permissions.append(try simulatorPrivacyPermission(
                profileName: profileName,
                action: .revoke,
                rawEntry: entry
            ))
        }
        for entry in try stringArray(profileName: profileName, section: "privacy", key: "reset", reader: reader) {
            permissions.append(try simulatorPrivacyPermission(
                profileName: profileName,
                action: .reset,
                rawEntry: entry
            ))
        }
        return SimulatorPrivacySettings(permissions: permissions)
    }

    static func managedSimulator(profileName: String, reader: TOMLSectionReader) throws -> ManagedSimulator? {
        guard !reader.isEmpty else {
            return nil
        }
        try validateKnownKeys(
            profileName: profileName,
            section: "managed_simulator",
            reader: reader,
            allowedKeys: ["name", "device_type", "runtime", "clone_for_shards"]
        )
        let managedName = try requiredTrimmedString(
            profileName: profileName,
            section: "managed_simulator",
            key: "name",
            reader: reader
        )
        let deviceType = try requiredTrimmedString(
            profileName: profileName,
            section: "managed_simulator",
            key: "device_type",
            reader: reader
        )
        let runtime = try requiredTrimmedString(
            profileName: profileName,
            section: "managed_simulator",
            key: "runtime",
            reader: reader
        )
        return ManagedSimulator(
            name: managedName,
            deviceType: deviceType,
            runtime: runtime,
            cloneForShards: try optionalBool(
                profileName: profileName,
                keyPath: "managed_simulator.clone_for_shards",
                reader: reader,
                key: "clone_for_shards"
            ) ?? false
        )
    }

    static func env(profileName: String, reader: TOMLSectionReader) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in reader.values.keys.sorted() {
            guard case let .string(value) = reader.values[key] else {
                throw XCStewardError.invalidConfiguration("Profile \(profileName) env.\(key) must be a string")
            }
            result[key] = value
        }
        return result
    }

    static func timeouts(profileName: String, reader: TOMLSectionReader) throws -> Timeouts {
        try validateKnownKeys(
            profileName: profileName,
            section: "timeouts",
            reader: reader,
            allowedKeys: ["boot", "build", "test"]
        )
        return try Timeouts(
            boot: positiveTimeout(
                profileName: profileName,
                key: "boot",
                value: try optionalInteger(profileName: profileName, keyPath: "timeouts.boot", reader: reader, key: "boot") ?? 30
            ),
            build: positiveTimeout(
                profileName: profileName,
                key: "build",
                value: try optionalInteger(profileName: profileName, keyPath: "timeouts.build", reader: reader, key: "build") ?? 600
            ),
            test: positiveTimeout(
                profileName: profileName,
                key: "test",
                value: try optionalInteger(profileName: profileName, keyPath: "timeouts.test", reader: reader, key: "test") ?? 600
            )
        )
    }

    static func resetPolicy(profileName: String, root: TOMLSectionReader) throws -> String? {
        let resetPolicy = try optionalEnumString(
            profileName: profileName,
            keyPath: "reset_policy",
            reader: root,
            key: "reset_policy"
        )
        if let resetPolicy, !["none", "shutdown", "erase"].contains(resetPolicy) {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) has unsupported reset_policy '\(resetPolicy)'")
        }
        return resetPolicy
    }

    private static func simulatorPrivacyPermission(
        profileName: String,
        action: SimulatorPrivacyAction,
        rawEntry: String
    ) throws -> SimulatorPrivacyPermission {
        let parts = rawEntry
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 1 || parts.count == 2 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) privacy.\(action.rawValue) entry must be 'service' or 'service:bundle.identifier'")
        }
        let service = parts[0].lowercased()
        guard supportedSimulatorPrivacyServices.contains(service) else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) privacy.\(action.rawValue) has unsupported service '\(service)'")
        }
        let bundleIdentifier = parts.count == 2 ? parts[1] : nil
        switch action {
        case .grant, .revoke:
            guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
                throw XCStewardError.invalidConfiguration("Profile \(profileName) privacy.\(action.rawValue) entry '\(rawEntry)' requires a bundle identifier")
            }
        case .reset:
            if let bundleIdentifier, bundleIdentifier.isEmpty {
                throw XCStewardError.invalidConfiguration("Profile \(profileName) privacy.reset entry '\(rawEntry)' has an empty bundle identifier")
            }
        }
        return SimulatorPrivacyPermission(action: action, service: service, bundleIdentifier: bundleIdentifier)
    }

    private static func requiredTrimmedString(
        profileName: String,
        section: String,
        key: String,
        reader: TOMLSectionReader
    ) throws -> String {
        guard let value = try optionalString(
            profileName: profileName,
            keyPath: "\(section).\(key)",
            reader: reader,
            key: key
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(section).\(key) must be a non-empty string")
        }
        return value
    }

    private static func requiredBool(
        profileName: String,
        section: String,
        key: String,
        reader: TOMLSectionReader
    ) throws -> Bool {
        guard let value = reader.values[key] else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(section).\(key) is required when [\(section)] is present")
        }
        guard case let .bool(boolean) = value else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(section).\(key) must be a boolean")
        }
        return boolean
    }

    private static func optionalBool(
        profileName: String,
        section: String,
        key: String,
        reader: TOMLSectionReader
    ) throws -> Bool? {
        guard let value = reader.values[key] else {
            return nil
        }
        guard case let .bool(boolean) = value else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(section).\(key) must be a boolean")
        }
        return boolean
    }

    private static func requiredInteger(
        profileName: String,
        section: String,
        key: String,
        reader: TOMLSectionReader
    ) throws -> Int {
        guard let value = reader.values[key] else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(section).\(key) is required when [\(section)] is present")
        }
        guard case let .integer(number) = value else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(section).\(key) must be an integer")
        }
        return number
    }

    private static func validateKnownKeys(
        profileName: String,
        section: String,
        reader: TOMLSectionReader,
        allowedKeys: Set<String>
    ) throws {
        let unsupported = reader.values.keys.filter { !allowedKeys.contains($0) }.sorted()
        guard unsupported.isEmpty else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) [\(section)] has unsupported key '\(unsupported[0])'")
        }
    }

    private static func stringArray(
        profileName: String,
        section: String,
        key: String,
        reader: TOMLSectionReader
    ) throws -> [String] {
        guard let value = reader.values[key] else {
            return []
        }
        guard case let .array(values) = value else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(section).\(key) must be an array of strings")
        }
        return values
    }

    private static func optionalString(
        profileName: String,
        keyPath: String,
        reader: TOMLSectionReader,
        key: String
    ) throws -> String? {
        guard let value = reader.values[key] else {
            return nil
        }
        guard case let .string(string) = value else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(keyPath) must be a string")
        }
        return string
    }

    private static func optionalInteger(
        profileName: String,
        keyPath: String,
        reader: TOMLSectionReader,
        key: String
    ) throws -> Int? {
        guard let value = reader.values[key] else {
            return nil
        }
        guard case let .integer(number) = value else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(keyPath) must be an integer")
        }
        return number
    }

    private static func optionalBool(
        profileName: String,
        keyPath: String,
        reader: TOMLSectionReader,
        key: String
    ) throws -> Bool? {
        guard let value = reader.values[key] else {
            return nil
        }
        guard case let .bool(boolean) = value else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(keyPath) must be a boolean")
        }
        return boolean
    }

    private static func positiveTimeout(profileName: String, key: String, value: Int) throws -> TimeInterval {
        guard value >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) timeouts.\(key) must be >= 1")
        }
        return TimeInterval(value)
    }

    private static func optionalEnumString(
        profileName: String,
        keyPath: String,
        reader: TOMLSectionReader,
        key: String
    ) throws -> String? {
        guard let raw = try optionalString(
            profileName: profileName,
            keyPath: keyPath,
            reader: reader,
            key: key
        ) else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(keyPath) must be a non-empty string")
        }
        return value
    }

    private static let supportedSimulatorPrivacyServices: Set<String> = [
        "all",
        "calendar",
        "contacts-limited",
        "contacts",
        "location",
        "location-always",
        "photos-add",
        "photos",
        "media-library",
        "microphone",
        "motion",
        "reminders",
        "siri",
    ]
}
