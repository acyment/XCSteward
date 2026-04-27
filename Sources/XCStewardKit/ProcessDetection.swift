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
                return command.contains(" test") ||
                    command.contains("test-without-building") ||
                    command.contains("build-for-testing")
            }
            return false
        }
    }

    private static func isXCStewardOwned(_ command: String) -> Bool {
        executableNames(in: command).contains("xcsteward") || command.contains("ps -Ao pid,command")
    }

    private static func executableNames(in processLine: String) -> Set<String> {
        Set(
            processLine
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .map { URL(fileURLWithPath: $0).lastPathComponent }
        )
    }
}
