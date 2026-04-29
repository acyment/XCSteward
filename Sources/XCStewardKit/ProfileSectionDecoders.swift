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

    func stringMap() -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in values {
            if case let .string(string) = value {
                result[key] = string
            }
        }
        return result
    }
}

enum ProfileSectionDecoders {
    static func parallel(profileName: String, reader: TOMLSectionReader) throws -> ParallelSettings {
        let parallelModeRaw = reader.string("mode") ?? ParallelMode.xcodeManaged.rawValue
        guard let parallelMode = ParallelMode(rawValue: parallelModeRaw) else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) has unsupported parallel.mode '\(parallelModeRaw)'")
        }
        let maxWorkers = reader.integer("max_workers") ?? 1
        guard maxWorkers >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) parallel.max_workers must be >= 1")
        }
        let shardCount = reader.integer("shard_count") ?? 1
        guard shardCount >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) parallel.shard_count must be >= 1")
        }
        return ParallelSettings(
            mode: parallelMode,
            maxWorkers: maxWorkers,
            exactWorkers: reader.bool("exact_workers") ?? false,
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
        guard let base = reader.integer("base") else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) ports.base is required when [ports] is present")
        }
        let count = reader.integer("count") ?? 16
        let stride = reader.integer("stride") ?? 100
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
        let enabled = reader.bool("enabled") ?? true
        let defaultAllowance = reader.integer("default_execution_time_allowance") ?? 120
        let maximumAllowance = reader.integer("maximum_execution_time_allowance") ?? 600
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
        let enabled = reader.bool("enabled") ?? false
        let iterations = reader.integer("iterations") ?? 1
        let retryTestsOnFailure = reader.bool("retry_tests_on_failure") ?? true
        let runTestsUntilFailure = reader.bool("run_tests_until_failure") ?? false
        let relaunchBetweenIterations = reader.bool("relaunch_between_iterations")
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
        guard let collectRaw = reader.string("collect")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !collectRaw.isEmpty else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_diagnostics.collect is required when [test_diagnostics] is present")
        }
        guard let collect = XCTestDiagnosticCollectionMode(rawValue: collectRaw) else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_diagnostics.collect must be 'on-failure' or 'never'")
        }
        return XCTestDiagnosticSettings(collect: collect)
    }

    static func destination(profileName: String, reader: TOMLSectionReader) throws -> XcodeDestinationSettings {
        guard let timeout = reader.integer("timeout") else {
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
        guard let enabled = reader.bool("enabled") else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) coverage.enabled is required when [coverage] is present")
        }
        return CodeCoverageSettings(enabled: enabled)
    }

    static func resultStream(profileName: String, reader: TOMLSectionReader) throws -> ResultStreamSettings {
        guard !reader.isEmpty else {
            return ResultStreamSettings()
        }
        guard let enabled = reader.bool("enabled") else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) result_stream.enabled is required when [result_stream] is present")
        }
        return ResultStreamSettings(enabled: enabled)
    }

    static func resultBundle(profileName: String, reader: TOMLSectionReader) throws -> ResultBundleSettings {
        guard !reader.isEmpty else {
            return ResultBundleSettings()
        }
        guard let version = reader.integer("version") else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) result_bundle.version is required when [result_bundle] is present")
        }
        guard version >= 1 else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) result_bundle.version must be >= 1")
        }
        return ResultBundleSettings(version: version)
    }

    static func testProducts(profileName: String, reader: TOMLSectionReader) throws -> TestProductsSettings {
        let enabled = reader.bool("enabled") ?? false
        let useForTesting = reader.bool("use_for_testing") ?? false
        if useForTesting && !enabled {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) test_products.use_for_testing requires enabled = true")
        }
        return TestProductsSettings(enabled: enabled, useForTesting: useForTesting)
    }

    static func privacy(profileName: String, reader: TOMLSectionReader) throws -> SimulatorPrivacySettings {
        guard !reader.isEmpty else {
            return SimulatorPrivacySettings()
        }
        var permissions: [SimulatorPrivacyPermission] = []
        for entry in reader.array("grant") {
            permissions.append(try simulatorPrivacyPermission(
                profileName: profileName,
                action: .grant,
                rawEntry: entry
            ))
        }
        for entry in reader.array("revoke") {
            permissions.append(try simulatorPrivacyPermission(
                profileName: profileName,
                action: .revoke,
                rawEntry: entry
            ))
        }
        for entry in reader.array("reset") {
            permissions.append(try simulatorPrivacyPermission(
                profileName: profileName,
                action: .reset,
                rawEntry: entry
            ))
        }
        return SimulatorPrivacySettings(permissions: permissions)
    }

    static func managedSimulator(reader: TOMLSectionReader) -> ManagedSimulator? {
        guard let managedName = reader.string("name"),
              let deviceType = reader.string("device_type"),
              let runtime = reader.string("runtime") else {
            return nil
        }
        return ManagedSimulator(
            name: managedName,
            deviceType: deviceType,
            runtime: runtime,
            cloneForShards: reader.bool("clone_for_shards") ?? false
        )
    }

    static func env(reader: TOMLSectionReader) -> [String: String] {
        reader.stringMap()
    }

    static func timeouts(reader: TOMLSectionReader) -> Timeouts {
        Timeouts(
            boot: TimeInterval(reader.integer("boot") ?? 30),
            build: TimeInterval(reader.integer("build") ?? 600),
            test: TimeInterval(reader.integer("test") ?? 600)
        )
    }

    static func resetPolicy(profileName: String, root: TOMLSectionReader) throws -> String? {
        let resetPolicy = root.string("reset_policy")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        let service = parts[0]
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
