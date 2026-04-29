import Foundation

protocol SimulatorLifecycleTooling: AnyObject {
    func runTool(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext,
        environmentOverrides: [String: String]
    ) throws -> ToolResult
    func throwIfCanceled(_ result: ToolResult, context: ToolExecutionContext) throws
    func commandFailed(_ message: String, output: String) -> XCStewardError
    func failAndLog(message: String, exitCode: Int32, logURL: URL, combinedLog: URL) throws -> ToolResult
}

extension SimulatorLifecycleTooling {
    func runTool(
        tool: String,
        arguments: [String],
        timeout: TimeInterval,
        context: ToolExecutionContext
    ) throws -> ToolResult {
        try runTool(
            tool: tool,
            arguments: arguments,
            timeout: timeout,
            context: context,
            environmentOverrides: [:]
        )
    }
}

final class SimulatorLifecycle: @unchecked Sendable {
    private let environment: AppEnvironment
    private unowned let tooling: SimulatorLifecycleTooling

    init(environment: AppEnvironment, tooling: SimulatorLifecycleTooling) {
        self.environment = environment
        self.tooling = tooling
    }

    func resolveSimulatorID(request: JobRequest, context: ToolExecutionContext) throws -> String {
        let profile = context.profile
        if let requestedSimulatorID = request.simulatorID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedSimulatorID.isEmpty {
            if !profile.allowedSimulatorIDs.isEmpty,
               !profile.allowedSimulatorIDs.contains(requestedSimulatorID),
               requestedSimulatorID != profile.defaultSimulatorID {
                throw XCStewardError.invalidConfiguration("Requested simulator override \(requestedSimulatorID) is not allowed by profile \(profile.name)")
            }
            return requestedSimulatorID
        }
        if let defaultSimulatorID = profile.defaultSimulatorID {
            return defaultSimulatorID
        }
        if let managed = profile.managedSimulator {
            return try resolveManagedSimulator(managed, context: context)
        }
        throw XCStewardError.invalidConfiguration("Profile \(profile.name) has no simulator assignment")
    }

    func bootSimulator(simulatorID: String, context: ToolExecutionContext) throws {
        let profile = context.profile
        let boot = try runSimulatorBoot(simulatorID: simulatorID, context: context)
        let alreadyBooted = boot.output.contains("current state: Booted")

        do {
            try confirmBootStatus(
                simulatorID: simulatorID,
                timeout: alreadyBooted ? profile.timeouts.boot : max(profile.timeouts.boot, 240),
                context: context
            )
        } catch {
            guard alreadyBooted,
                  String(describing: error).contains("Unable to confirm simulator boot status") else {
                throw error
            }
            let shutdown = try tooling.runTool(
                tool: "xcrun",
                arguments: ["simctl", "shutdown", simulatorID],
                timeout: profile.timeouts.boot,
                context: context
            )
            try tooling.throwIfCanceled(shutdown, context: context)
            _ = try runSimulatorBoot(simulatorID: simulatorID, context: context)
            try confirmBootStatus(
                simulatorID: simulatorID,
                timeout: max(profile.timeouts.boot, 240),
                context: context
            )
        }
    }

    func preparePrivacy(
        simulatorID: String,
        logURL: URL,
        combinedLog: URL,
        context: ToolExecutionContext
    ) throws {
        guard !context.profile.privacy.isEmpty else {
            return
        }
        for permission in context.profile.privacy.permissions {
            let arguments = simulatorPrivacyArguments(simulatorID: simulatorID, permission: permission)
            let result = try tooling.runTool(
                tool: "xcrun",
                arguments: arguments,
                timeout: context.profile.timeouts.boot,
                context: context
            )
            try tooling.throwIfCanceled(result, context: context)
            guard result.exitCode == 0, !result.timedOut else {
                let message = "Unable to configure simulator privacy for \(simulatorID): simctl privacy \(privacyDescription(permission))"
                _ = try? tooling.failAndLog(
                    message: message,
                    exitCode: result.exitCode,
                    logURL: logURL,
                    combinedLog: combinedLog
                )
                throw tooling.commandFailed(message, output: result.output)
            }
            try appendPrivacyLogLine(
                simulatorID: simulatorID,
                permission: permission,
                logURL: logURL,
                combinedLog: combinedLog
            )
        }
    }

    @discardableResult
    func captureDiagnostics(
        simulatorID: String,
        outputURL: URL,
        context: ToolExecutionContext
    ) -> String? {
        let result = try? tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "diagnose", "-l"],
            timeout: context.profile.timeouts.boot,
            context: context
        )
        var text = [
            "simulator_id=\(simulatorID)",
            "command=xcrun simctl diagnose -l",
        ].joined(separator: "\n")
        text.append("\n")
        if let result {
            text.append("exit_code=\(result.exitCode)\n")
            text.append("timed_out=\(result.timedOut)\n")
            text.append(result.output)
            if !result.output.hasSuffix("\n") {
                text.append("\n")
            }
        } else {
            text.append("diagnose invocation failed\n")
        }
        try? environment.fileSystem.writeData(Data(text.utf8), to: outputURL)
        return environment.fileSystem.fileExists(outputURL) ? outputURL.path : nil
    }

    func cleanupAfterJob(simulatorID: String, context: ToolExecutionContext) {
        let simulatorID = simulatorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !simulatorID.isEmpty else {
            return
        }
        switch context.profile.resetPolicy {
        case "shutdown":
            _ = try? tooling.runTool(
                tool: "xcrun",
                arguments: ["simctl", "shutdown", simulatorID],
                timeout: context.profile.timeouts.boot,
                context: context
            )
        case "erase":
            _ = try? tooling.runTool(
                tool: "xcrun",
                arguments: ["simctl", "shutdown", simulatorID],
                timeout: context.profile.timeouts.boot,
                context: context
            )
            _ = try? tooling.runTool(
                tool: "xcrun",
                arguments: ["simctl", "erase", simulatorID],
                timeout: context.profile.timeouts.boot,
                context: context
            )
        case "none", nil:
            return
        default:
            return
        }
    }

    func shutdownSimulatorForCloneTemplate(simulatorID: String, context: ToolExecutionContext) throws {
        let shutdown = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "shutdown", simulatorID],
            timeout: context.profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(shutdown, context: context)
        if shutdown.exitCode != 0 && !shutdown.output.contains("current state: Shutdown") {
            throw tooling.commandFailed("Unable to shutdown simulator \(simulatorID) before cloning", output: shutdown.output)
        }
    }

    func cloneManagedShardSimulator(
        templateSimulatorID: String,
        managed: ManagedSimulator,
        shardIndex: Int,
        context: ToolExecutionContext
    ) throws -> String {
        let cloneName = "\(managed.name)-xcsteward-\(shortJobID(context.jobID))-shard-\(shardIndex)"
        let clone = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "clone", templateSimulatorID, cloneName],
            timeout: context.profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(clone, context: context)
        if clone.exitCode != 0 || clone.timedOut {
            throw tooling.commandFailed("Unable to clone managed simulator '\(managed.name)' for shard \(shardIndex)", output: clone.output)
        }
        guard let clonedSimulatorID = parseCreatedSimulatorID(from: clone.output) else {
            throw tooling.commandFailed(
                "Unable to clone managed simulator '\(managed.name)' for shard \(shardIndex): expected a single simulator UDID in simctl clone output",
                output: clone.output
            )
        }
        return clonedSimulatorID
    }

    func recoverForShardRetry(simulatorID: String, context: ToolExecutionContext) throws {
        let shutdown = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "shutdown", simulatorID],
            timeout: context.profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(shutdown, context: context)
        let erase = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "erase", simulatorID],
            timeout: context.profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(erase, context: context)
        try bootSimulator(simulatorID: simulatorID, context: context)
    }

    func deleteTransientSimulatorAfterJob(simulatorID: String, context: ToolExecutionContext) {
        let simulatorID = simulatorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !simulatorID.isEmpty else {
            return
        }
        _ = try? tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "shutdown", simulatorID],
            timeout: context.profile.timeouts.boot,
            context: context
        )
        _ = try? tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "delete", simulatorID],
            timeout: context.profile.timeouts.boot,
            context: context
        )
    }

    func parseCreatedSimulatorID(from output: String) -> String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == 1, isSimulatorUDID(lines[0]) else {
            return nil
        }
        return lines[0]
    }

    func existingManagedSimulatorID(_ managed: ManagedSimulator, context: ToolExecutionContext) throws -> String? {
        let profile = context.profile
        let list = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "list", "devices"],
            timeout: profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(list, context: context)
        if list.exitCode != 0 || list.timedOut {
            throw tooling.commandFailed("Unable to list simulators for managed simulator '\(managed.name)'", output: list.output)
        }
        return parseSimulatorID(from: list.output, preferredName: managed.name)
    }

    func createManagedSimulator(_ managed: ManagedSimulator, context: ToolExecutionContext) throws -> String {
        let profile = context.profile
        let create = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "create", managed.name, managed.deviceType, managed.runtime],
            timeout: profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(create, context: context)
        if create.exitCode != 0 || create.timedOut {
            throw tooling.commandFailed("Unable to create managed simulator '\(managed.name)'", output: create.output)
        }
        if let created = parseCreatedSimulatorID(from: create.output) {
            return created
        }
        throw tooling.commandFailed("Unable to create managed simulator '\(managed.name)': expected a single simulator UDID in simctl create output", output: create.output)
    }

    private func resolveManagedSimulator(_ managed: ManagedSimulator, context: ToolExecutionContext) throws -> String {
        if let existing = try existingManagedSimulatorID(managed, context: context) {
            return existing
        }
        return try createManagedSimulator(managed, context: context)
    }

    private func runSimulatorBoot(simulatorID: String, context: ToolExecutionContext) throws -> ToolResult {
        let boot = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "boot", simulatorID],
            timeout: context.profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(boot, context: context)
        if boot.exitCode != 0 && !boot.output.contains("current state: Booted") {
            throw XCStewardError.commandFailed("Unable to boot simulator \(simulatorID)")
        }
        return boot
    }

    private func confirmBootStatus(simulatorID: String, timeout: TimeInterval, context: ToolExecutionContext) throws {
        let bootStatus = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "bootstatus", simulatorID, "-b"],
            timeout: timeout,
            context: context
        )
        try tooling.throwIfCanceled(bootStatus, context: context)
        guard bootStatus.exitCode == 0, !bootStatus.timedOut else {
            throw bootStatusError(simulatorID: simulatorID, result: bootStatus)
        }
    }

    private func bootStatusError(simulatorID: String, result: ToolResult) -> XCStewardError {
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return .commandFailed("Unable to confirm simulator boot status for \(simulatorID)")
        }
        return .commandFailed("Unable to confirm simulator boot status for \(simulatorID): \(detail)")
    }

    private func parseSimulatorID(from output: String, preferredName: String?) -> String? {
        for line in output.split(separator: "\n") {
            let string = String(line)
            if let preferredName, !string.contains(preferredName) { continue }
            var searchStart = string.startIndex
            while let open = string[searchStart...].firstIndex(of: "("),
                  let close = string[open...].dropFirst().firstIndex(of: ")") {
                let candidate = String(string[string.index(after: open)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty && !isSimulatorStatus(candidate) {
                    return candidate
                }
                searchStart = string.index(after: close)
            }
        }
        return nil
    }

    private func simulatorPrivacyArguments(
        simulatorID: String,
        permission: SimulatorPrivacyPermission
    ) -> [String] {
        var arguments = [
            "simctl",
            "privacy",
            simulatorID,
            permission.action.rawValue,
            permission.service,
        ]
        if let bundleIdentifier = permission.bundleIdentifier {
            arguments.append(bundleIdentifier)
        }
        return arguments
    }

    private func appendPrivacyLogLine(
        simulatorID: String,
        permission: SimulatorPrivacyPermission,
        logURL: URL,
        combinedLog: URL
    ) throws {
        let output = "Configured simulator privacy for \(simulatorID): \(privacyDescription(permission))\n"
        let data = Data(output.utf8)
        try environment.fileSystem.appendData(data, to: logURL)
        try environment.fileSystem.appendData(data, to: combinedLog)
    }

    private func privacyDescription(_ permission: SimulatorPrivacyPermission) -> String {
        var parts = [permission.action.rawValue, permission.service]
        if let bundleIdentifier = permission.bundleIdentifier {
            parts.append(bundleIdentifier)
        }
        return parts.joined(separator: " ")
    }

    private func shortJobID(_ jobID: String) -> String {
        let sanitized = jobID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return String((sanitized.isEmpty ? "job" : sanitized).prefix(8))
    }

    private func isSimulatorUDID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        let expectedLengths = [8, 4, 4, 4, 12]
        guard parts.count == expectedLengths.count else {
            return false
        }
        for (part, expectedLength) in zip(parts, expectedLengths) {
            guard part.count == expectedLength,
                  part.allSatisfy({ $0.isHexDigit }) else {
                return false
            }
        }
        return true
    }

    private func isSimulatorStatus(_ value: String) -> Bool {
        let statuses: Set<String> = [
            "Shutdown",
            "Booted",
            "Creating",
            "Shutting Down",
        ]
        return statuses.contains(value)
    }
}
