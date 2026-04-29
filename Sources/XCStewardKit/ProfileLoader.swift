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
        let reader = TOMLProfileReader(raw: raw)
        let root = reader.root
        guard let repoRoot = root.string("repo_root"),
              let scheme = root.string("scheme") else {
            throw XCStewardError.invalidConfiguration("Profile \(name) is missing repo_root or scheme")
        }
        let parallel = try ProfileSectionDecoders.parallel(
            profileName: name,
            reader: reader.section("parallel")
        )
        let ports = try ProfileSectionDecoders.ports(
            profileName: name,
            reader: reader.section("ports"),
            shardCount: parallel.shardCount
        )
        let xctestTimeouts = try ProfileSectionDecoders.xctestTimeouts(
            profileName: name,
            reader: reader.section("test_timeouts")
        )
        let xctestRetries = try ProfileSectionDecoders.xctestRetries(
            profileName: name,
            reader: reader.section("test_retries")
        )
        let xctestDiagnostics = try ProfileSectionDecoders.xctestDiagnostics(
            profileName: name,
            reader: reader.section("test_diagnostics")
        )
        let destination = try ProfileSectionDecoders.destination(
            profileName: name,
            reader: reader.section("destination")
        )
        let coverage = try ProfileSectionDecoders.coverage(
            profileName: name,
            reader: reader.section("coverage")
        )
        let resultStream = try ProfileSectionDecoders.resultStream(
            profileName: name,
            reader: reader.section("result_stream")
        )
        let resultBundle = try ProfileSectionDecoders.resultBundle(
            profileName: name,
            reader: reader.section("result_bundle")
        )
        let testProducts = try ProfileSectionDecoders.testProducts(
            profileName: name,
            reader: reader.section("test_products")
        )
        let privacy = try ProfileSectionDecoders.privacy(
            profileName: name,
            reader: reader.section("privacy")
        )
        let managedSimulator = ProfileSectionDecoders.managedSimulator(reader: reader.section("managed_simulator"))
        let envValues = ProfileSectionDecoders.env(reader: reader.section("env"))
        let timeouts = ProfileSectionDecoders.timeouts(reader: reader.section("timeouts"))
        let resetPolicy = try ProfileSectionDecoders.resetPolicy(profileName: name, root: root)
        return ProjectProfile(
            name: name,
            repoRoot: repoRoot,
            projectPath: root.string("project_path"),
            workspacePath: root.string("workspace_path"),
            scheme: scheme,
            defaultSimulatorID: root.string("default_simulator_id"),
            managedSimulator: managedSimulator,
            defaultTestPlan: root.string("default_test_plan"),
            allowedSimulatorIDs: root.array("allowed_simulator_ids"),
            env: envValues,
            timeouts: timeouts,
            resetPolicy: resetPolicy,
            parallel: parallel,
            ports: ports,
            xctestTimeouts: xctestTimeouts,
            xctestRetries: xctestRetries,
            xctestDiagnostics: xctestDiagnostics,
            destination: destination,
            coverage: coverage,
            resultStream: resultStream,
            resultBundle: resultBundle,
            testProducts: testProducts,
            privacy: privacy
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
