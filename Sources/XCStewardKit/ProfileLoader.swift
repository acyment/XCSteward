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
        guard root.values["repo_root"] != nil,
              root.values["scheme"] != nil else {
            throw XCStewardError.invalidConfiguration("Profile \(name) is missing repo_root or scheme")
        }
        let repoRoot = try requiredRootString("repo_root", profileName: name, root: root)
        let scheme = try requiredRootString("scheme", profileName: name, root: root)
        let projectPath = try optionalRootString("project_path", profileName: name, root: root)
        let workspacePath = try optionalRootString("workspace_path", profileName: name, root: root)
        try validateBuildContainer(
            profileName: name,
            projectPath: projectPath,
            workspacePath: workspacePath
        )
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
        let managedSimulator = try ProfileSectionDecoders.managedSimulator(
            profileName: name,
            reader: reader.section("managed_simulator")
        )
        let envValues = try ProfileSectionDecoders.env(
            profileName: name,
            reader: reader.section("env")
        )
        let timeouts = try ProfileSectionDecoders.timeouts(
            profileName: name,
            reader: reader.section("timeouts")
        )
        let resetPolicy = try ProfileSectionDecoders.resetPolicy(profileName: name, root: root)
        return ProjectProfile(
            name: name,
            repoRoot: repoRoot,
            projectPath: projectPath,
            workspacePath: workspacePath,
            scheme: scheme,
            defaultSimulatorID: try optionalRootString("default_simulator_id", profileName: name, root: root),
            managedSimulator: managedSimulator,
            defaultTestPlan: try optionalRootString("default_test_plan", profileName: name, root: root),
            allowedSimulatorIDs: try trimmedRootArray("allowed_simulator_ids", profileName: name, root: root),
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

    private func requiredRootString(
        _ key: String,
        profileName: String,
        root: TOMLSectionReader
    ) throws -> String {
        guard let value = try optionalRootString(key, profileName: profileName, root: root) else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(key) must be a non-empty string")
        }
        return value
    }

    private func optionalRootString(_ key: String, profileName: String, root: TOMLSectionReader) throws -> String? {
        guard let rawValue = root.values[key] else {
            return nil
        }
        guard case let .string(string) = rawValue else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(key) must be a string")
        }
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        return value
    }

    private func validateBuildContainer(
        profileName: String,
        projectPath: String?,
        workspacePath: String?
    ) throws {
        switch (projectPath, workspacePath) {
        case (nil, nil):
            throw XCStewardError.invalidConfiguration("Profile \(profileName) must set exactly one of project_path or workspace_path")
        case (.some, .some):
            throw XCStewardError.invalidConfiguration("Profile \(profileName) must not set both project_path and workspace_path")
        default:
            return
        }
    }

    private func trimmedRootArray(_ key: String, profileName: String, root: TOMLSectionReader) throws -> [String] {
        guard let rawValue = root.values[key] else {
            return []
        }
        guard case let .array(values) = rawValue else {
            throw XCStewardError.invalidConfiguration("Profile \(profileName) \(key) must be an array of strings")
        }
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func parseTOML(_ text: String) throws -> [String: [String: TOMLValue]] {
        var result: [String: [String: TOMLValue]] = [:]
        var currentSection = ""
        result[currentSection] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = stripInlineComment(from: String(rawLine)).trimmingCharacters(in: .whitespaces)
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

    private func stripInlineComment(from line: String) -> String {
        var result = ""
        var inString = false
        var escaping = false
        for character in line {
            if escaping {
                result.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                result.append(character)
                escaping = true
                continue
            }
            if character == "\"" {
                result.append(character)
                inString.toggle()
                continue
            }
            if character == "#", !inString {
                break
            }
            result.append(character)
        }
        return result
    }

    private func parseValue(_ raw: String) throws -> TOMLValue {
        if raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return .string(String(raw.dropFirst().dropLast()))
        }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = raw.dropFirst().dropLast()
            return .array(try parseStringArray(inner))
        }
        if raw == "true" || raw == "false" {
            return .bool(raw == "true")
        }
        if let integer = Int(raw) {
            return .integer(integer)
        }
        throw XCStewardError.invalidConfiguration("Unsupported TOML value: \(raw)")
    }

    private func parseStringArray(_ inner: Substring) throws -> [String] {
        let text = String(inner)
        var values: [String] = []
        var index = text.startIndex

        func skipWhitespace() {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
        }

        skipWhitespace()
        while index < text.endIndex {
            guard text[index] == "\"" else {
                throw XCStewardError.invalidConfiguration("TOML arrays must contain quoted strings")
            }
            index = text.index(after: index)

            var value = ""
            var escaping = false
            var closed = false
            while index < text.endIndex {
                let character = text[index]
                if escaping {
                    value.append(character)
                    escaping = false
                    index = text.index(after: index)
                    continue
                }
                if character == "\\" {
                    value.append(character)
                    escaping = true
                    index = text.index(after: index)
                    continue
                }
                if character == "\"" {
                    closed = true
                    index = text.index(after: index)
                    break
                }
                value.append(character)
                index = text.index(after: index)
            }
            guard closed else {
                throw XCStewardError.invalidConfiguration("Unterminated TOML string in array")
            }
            values.append(value)

            skipWhitespace()
            guard index < text.endIndex else {
                break
            }
            guard text[index] == "," else {
                throw XCStewardError.invalidConfiguration("TOML array entries must be separated by commas")
            }
            index = text.index(after: index)
            skipWhitespace()
        }

        return values
    }
}
