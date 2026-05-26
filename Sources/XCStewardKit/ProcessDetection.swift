import Foundation

struct ProcessRecord {
    let pid: Int32
    let command: String
}

enum RunnerProcessPolicy {
    case doctor
    case executor
}

enum RunnerProcessDetector {
    private static let executorXcodebuildActions: Set<String> = [
        "build-for-testing",
        "test",
        "test-without-building",
    ]
    private static let xcodebuildOptionsWithValues: Set<String> = [
        "-configuration",
        "-destination",
        "-destination-timeout",
        "-derivedDataPath",
        "-maximum-parallel-testing-workers",
        "-only-test-configuration",
        "-parallel-testing-worker-count",
        "-project",
        "-resultBundlePath",
        "-resultBundleVersion",
        "-resultStreamPath",
        "-scheme",
        "-sdk",
        "-skip-test-configuration",
        "-testPlan",
        "-testProductsPath",
        "-workspace",
        "-xctestrun",
    ]

    static func records(from processListOutput: String) -> [ProcessRecord] {
        processListOutput
            .split(separator: "\n")
            .dropFirst()
            .compactMap { parseProcessLine(String($0)) }
    }

    static func parseProcessLine(_ processLine: String) -> ProcessRecord? {
        let trimmed = processLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2, let pid = Int32(parts[0]) else {
            return nil
        }
        return ProcessRecord(pid: pid, command: String(parts[1]).trimmingCharacters(in: .whitespaces))
    }

    static func isCompeting(command: String, policy: RunnerProcessPolicy) -> Bool {
        guard !command.isEmpty else {
            return false
        }
        if isXCStewardOwned(command) {
            return false
        }

        let executables = executableNames(in: command)
        switch policy {
        case .doctor:
            if executables.contains("xcodebuild") || executables.contains("xctest") {
                return true
            }
            return executables.contains("simctl")
        case .executor:
            if executables.contains("xctest") {
                return true
            }
            if executables.contains("xcodebuild") {
                return hasExecutorXcodebuildAction(command)
            }
            return false
        }
    }

    private static func isXCStewardOwned(_ command: String) -> Bool {
        executableNames(in: command).contains("xcsteward") || command.contains("ps -Ao pid,command")
    }

    private static func executableNames(in processLine: String) -> Set<String> {
        Set(
            commandTokens(in: processLine)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
        )
    }

    private static func hasExecutorXcodebuildAction(_ command: String) -> Bool {
        let tokens = commandTokens(in: command)
        guard let xcodebuildIndex = tokens.firstIndex(where: {
            URL(fileURLWithPath: $0).lastPathComponent == "xcodebuild"
        }) else {
            return false
        }
        var skipNextValue = false
        for token in tokens.dropFirst(xcodebuildIndex + 1) {
            if skipNextValue {
                skipNextValue = false
                continue
            }
            if executorXcodebuildActions.contains(token) {
                return true
            }
            if xcodebuildOptionsWithValues.contains(token) {
                skipNextValue = true
            }
        }
        return false
    }

    private static func commandTokens(in command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        func flushToken() {
            guard !current.isEmpty else {
                return
            }
            tokens.append(current)
            current = ""
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                flushToken()
            } else {
                current.append(character)
            }
        }

        if escaping {
            current.append("\\")
        }
        flushToken()
        return tokens
    }
}
