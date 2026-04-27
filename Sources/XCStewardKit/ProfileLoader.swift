import Foundation

public enum TOMLValue {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case array([String])
}

public struct ProfileLoader {
    public let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public func loadProfile(named name: String) throws -> ProjectProfile {
        let url = environment.paths.projectsRoot.appendingPathComponent("\(name).toml")
        guard environment.fileSystem.fileExists(url) else {
            throw XCStewardError.notFound("Profile '\(name)' not found at \(url.path)")
        }
        let data = try environment.fileSystem.readData(from: url)
        let text = String(data: data, encoding: .utf8) ?? ""
        let raw = try parseTOML(text)
        return try materializeProfile(name: name, raw: raw)
    }

    private func materializeProfile(name: String, raw: [String: [String: TOMLValue]]) throws -> ProjectProfile {
        func string(_ key: String, in section: String = "") -> String? {
            guard let value = raw[section]?[key] else { return nil }
            if case let .string(string) = value { return string }
            return nil
        }
        func array(_ key: String, in section: String = "") -> [String] {
            guard let value = raw[section]?[key] else { return [] }
            if case let .array(values) = value { return values }
            return []
        }
        func integer(_ key: String, in section: String = "") -> Int? {
            guard let value = raw[section]?[key] else { return nil }
            if case let .integer(number) = value { return number }
            return nil
        }
        guard let repoRoot = string("repo_root"),
              let scheme = string("scheme") else {
            throw XCStewardError.invalidConfiguration("Profile \(name) is missing repo_root or scheme")
        }
        let managedSimulator: ManagedSimulator?
        if let managedName = string("name", in: "managed_simulator"),
           let deviceType = string("device_type", in: "managed_simulator"),
           let runtime = string("runtime", in: "managed_simulator") {
            managedSimulator = ManagedSimulator(name: managedName, deviceType: deviceType, runtime: runtime)
        } else {
            managedSimulator = nil
        }
        var envValues: [String: String] = [:]
        for (key, value) in raw["env"] ?? [:] {
            if case let .string(string) = value {
                envValues[key] = string
            }
        }
        let timeouts = Timeouts(
            boot: TimeInterval(integer("boot", in: "timeouts") ?? 30),
            build: TimeInterval(integer("build", in: "timeouts") ?? 600),
            test: TimeInterval(integer("test", in: "timeouts") ?? 600)
        )
        return ProjectProfile(
            name: name,
            repoRoot: repoRoot,
            projectPath: string("project_path"),
            workspacePath: string("workspace_path"),
            scheme: scheme,
            defaultSimulatorID: string("default_simulator_id"),
            managedSimulator: managedSimulator,
            defaultTestPlan: string("default_test_plan"),
            allowedSimulatorIDs: array("allowed_simulator_ids"),
            env: envValues,
            timeouts: timeouts,
            resetPolicy: string("reset_policy")
        )
    }

    func parseTOML(_ text: String) throws -> [String: [String: TOMLValue]] {
        var result: [String: [String: TOMLValue]] = [:]
        var currentSection = ""
        result[currentSection] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = String(trimmed.dropFirst().dropLast())
                result[currentSection] = result[currentSection] ?? [:]
                continue
            }
            guard let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            let rawValue = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            result[currentSection]?[key] = try parseValue(String(rawValue))
        }
        return result
    }

    private func parseValue(_ raw: String) throws -> TOMLValue {
        if raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = raw.dropFirst().dropLast()
            let values = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }.filter { !$0.isEmpty }
            return .array(values)
        }
        if raw == "true" || raw == "false" {
            return .bool(raw == "true")
        }
        if let integer = Int(raw) {
            return .integer(integer)
        }
        throw XCStewardError.invalidConfiguration("Unsupported TOML value: \(raw)")
    }
}
