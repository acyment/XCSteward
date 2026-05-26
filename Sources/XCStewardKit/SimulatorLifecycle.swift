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
            try validateConfiguredSimulatorID(
                requestedSimulatorID,
                source: "requested simulator override",
                context: context
            )
            return requestedSimulatorID
        }
        if let defaultSimulatorID = profile.defaultSimulatorID {
            try validateConfiguredSimulatorID(
                defaultSimulatorID,
                source: "default_simulator_id",
                context: context
            )
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
        let alreadyBooted = simctlOutput(boot.output, indicatesCurrentState: .booted)

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
        if shutdown.exitCode != 0 && !simctlOutput(shutdown.output, indicatesCurrentState: .shutdown) {
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
            arguments: ["simctl", "list", "devices", "--json"],
            timeout: profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(list, context: context)
        if list.exitCode != 0 || list.timedOut {
            throw tooling.commandFailed("Unable to list simulators for managed simulator '\(managed.name)'", output: list.output)
        }
        do {
            return try parseManagedSimulatorID(from: list.output, managed: managed)
        } catch {
            throw tooling.commandFailed("Unable to parse simulator list for managed simulator '\(managed.name)'", output: list.output)
        }
    }

    func validateConfiguredSimulatorID(
        _ simulatorID: String,
        source: String,
        context: ToolExecutionContext
    ) throws {
        let profile = context.profile
        let trimmedID = simulatorID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw XCStewardError.invalidConfiguration("Profile \(profile.name) has an empty \(source)")
        }
        let list = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "list", "devices", "--json"],
            timeout: profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(list, context: context)
        if list.exitCode != 0 || list.timedOut {
            throw tooling.commandFailed(
                "Unable to list simulators while validating \(source) \(trimmedID) for profile \(profile.name)",
                output: list.output
            )
        }
        let device: SimctlDevice?
        do {
            device = try simulatorDevice(withUDID: trimmedID, in: list.output)
        } catch {
            throw tooling.commandFailed(
                "Unable to parse simulator list while validating \(source) \(trimmedID) for profile \(profile.name)",
                output: list.output
            )
        }
        guard let device else {
            throw XCStewardError.invalidConfiguration(
                "Configured simulator \(trimmedID) from \(source) for profile \(profile.name) was not found by `xcrun simctl list devices --json`; refusing to fall back to another simulator"
            )
        }
        guard device.isAvailableForUse else {
            throw XCStewardError.invalidConfiguration(
                "Configured simulator \(trimmedID) from \(source) for profile \(profile.name) is unavailable according to `xcrun simctl list devices --json`; refusing to mutate simulator state"
            )
        }
    }

    func createManagedSimulator(_ managed: ManagedSimulator, context: ToolExecutionContext) throws -> String {
        let profile = context.profile
        let references = try managedSimulatorCreateReferences(managed, context: context)
        let create = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "create", managed.name, references.deviceType, references.runtime],
            timeout: profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(create, context: context)
        if create.exitCode != 0 || create.timedOut {
            throw tooling.commandFailed(
                "Unable to create managed simulator '\(managed.name)' using device type '\(references.deviceType)' and runtime '\(references.runtime)'",
                output: create.output
            )
        }
        if let created = parseCreatedSimulatorID(from: create.output) {
            return created
        }
        throw tooling.commandFailed("Unable to create managed simulator '\(managed.name)': expected a single simulator UDID in simctl create output", output: create.output)
    }

    private func managedSimulatorCreateReferences(
        _ managed: ManagedSimulator,
        context: ToolExecutionContext
    ) throws -> ManagedSimulatorCreateReferences {
        let deviceType = try managedSimulatorCreateDeviceTypeReference(managed, context: context)
        let runtime = try managedSimulatorCreateRuntimeReference(managed, context: context)
        return ManagedSimulatorCreateReferences(deviceType: deviceType, runtime: runtime)
    }

    private func managedSimulatorCreateDeviceTypeReference(
        _ managed: ManagedSimulator,
        context: ToolExecutionContext
    ) throws -> String {
        let configured = managed.deviceType.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCoreSimulatorIdentifier(configured, prefix: "com.apple.CoreSimulator.SimDeviceType.") {
            return configured
        }

        let list = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "list", "devicetypes", "--json"],
            timeout: context.profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(list, context: context)
        if list.exitCode != 0 || list.timedOut {
            throw tooling.commandFailed("Unable to list Simulator device types for managed simulator '\(managed.name)'", output: list.output)
        }

        let deviceTypes: SimctlDeviceTypeList
        do {
            deviceTypes = try JSONDecoder().decode(SimctlDeviceTypeList.self, from: Data(list.output.utf8))
        } catch {
            throw tooling.commandFailed("Unable to parse Simulator device type list for managed simulator '\(managed.name)'", output: list.output)
        }

        if let match = deviceTypes.devicetypes.first(where: { deviceTypeProbe($0, matches: configured) }),
           let identifier = trimmedNonEmpty(match.identifier) {
            return identifier
        }

        throw XCStewardError.invalidConfiguration(
            "Managed simulator '\(managed.name)' references unknown Simulator device type '\(configured)'; `xcrun simctl list devicetypes --json` did not contain a matching identifier or name"
        )
    }

    private func managedSimulatorCreateRuntimeReference(
        _ managed: ManagedSimulator,
        context: ToolExecutionContext
    ) throws -> String {
        let configured = managed.runtime.trimmingCharacters(in: .whitespacesAndNewlines)
        if isCoreSimulatorIdentifier(configured, prefix: "com.apple.CoreSimulator.SimRuntime.") {
            return configured
        }

        let list = try tooling.runTool(
            tool: "xcrun",
            arguments: ["simctl", "list", "runtimes", "--json"],
            timeout: context.profile.timeouts.boot,
            context: context
        )
        try tooling.throwIfCanceled(list, context: context)
        if list.exitCode != 0 || list.timedOut {
            throw tooling.commandFailed("Unable to list Simulator runtimes for managed simulator '\(managed.name)'", output: list.output)
        }

        let runtimes: CoreSimulatorRuntimeListProbe
        do {
            runtimes = try JSONDecoder().decode(CoreSimulatorRuntimeListProbe.self, from: Data(list.output.utf8))
        } catch {
            throw tooling.commandFailed("Unable to parse Simulator runtime list for managed simulator '\(managed.name)'", output: list.output)
        }

        if let match = runtimes.runtimes.first(where: { $0.isAvailable && runtimeProbe($0, matches: configured) }),
           let identifier = trimmedNonEmpty(match.identifier) {
            return identifier
        }
        if runtimes.runtimes.contains(where: { runtimeProbe($0, matches: configured) }) {
            throw XCStewardError.invalidConfiguration(
                "Managed simulator '\(managed.name)' references unavailable Simulator runtime '\(configured)'; refusing to create a simulator on an unavailable runtime"
            )
        }

        throw XCStewardError.invalidConfiguration(
            "Managed simulator '\(managed.name)' references unknown Simulator runtime '\(configured)'; `xcrun simctl list runtimes --json` did not contain a matching available runtime"
        )
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
        if boot.exitCode != 0 && !simctlOutput(boot.output, indicatesCurrentState: .booted) {
            throw tooling.commandFailed("Unable to boot simulator \(simulatorID)", output: boot.output)
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

    private enum SimulatorState: String {
        case booted
        case shutdown
    }

    private func simctlOutput(_ output: String, indicatesCurrentState expectedState: SimulatorState) -> Bool {
        output
            .split(whereSeparator: \.isNewline)
            .contains { line in
                let words = line
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map { String($0).lowercased() }
                guard let currentIndex = words.firstIndex(of: "current") else {
                    return false
                }
                let stateLabelIndex = currentIndex + 1
                let stateValueIndex = currentIndex + 2
                return words.indices.contains(stateValueIndex) &&
                    words[stateLabelIndex] == "state" &&
                    words[stateValueIndex] == expectedState.rawValue
            }
    }

    private func parseManagedSimulatorID(from output: String, managed: ManagedSimulator) throws -> String? {
        let data = Data(output.utf8)
        let list = try JSONDecoder().decode(SimctlDeviceList.self, from: data)
        let candidates = list.devices.flatMap { runtime, devices in
            devices.compactMap { device -> ManagedSimulatorCandidate? in
                guard device.name == managed.name,
                      device.isAvailableForUse,
                      device.matchesConfiguredDeviceType(managed.deviceType),
                      let udid = device.udid?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !udid.isEmpty else {
                    return nil
                }
                return ManagedSimulatorCandidate(
                    runtime: runtime,
                    udid: udid,
                    hasKnownMatchingDeviceType: device.hasKnownMatchingDeviceType(managed.deviceType)
                )
            }
        }
        let runtimeMatches = candidates.filter { CoreSimulatorRuntime.matches($0.runtime, managed.runtime) }
        if let runtimeMatch = preferredManagedSimulatorCandidate(in: runtimeMatches) {
            return runtimeMatch.udid
        }
        if let fallback = preferredManagedSimulatorCandidate(in: candidates) {
            return fallback.udid
        }
        return nil
    }

    private func simulatorDevice(withUDID udid: String, in output: String) throws -> SimctlDevice? {
        let data = Data(output.utf8)
        let list = try JSONDecoder().decode(SimctlDeviceList.self, from: data)
        return list.devices
            .flatMap(\.value)
            .first { device in
                device.udid?.trimmingCharacters(in: .whitespacesAndNewlines) == udid
            }
    }

    private func preferredManagedSimulatorCandidate(
        in candidates: [ManagedSimulatorCandidate]
    ) -> ManagedSimulatorCandidate? {
        candidates.first(where: \.hasKnownMatchingDeviceType) ?? candidates.first
    }

    private func deviceTypeProbe(_ deviceType: SimctlDeviceType, matches configured: String) -> Bool {
        if let identifier = trimmedNonEmpty(deviceType.identifier),
           CoreSimulatorDeviceType.matches(identifier, configured) {
            return true
        }
        if let name = trimmedNonEmpty(deviceType.name),
           CoreSimulatorDeviceType.matches(name, configured) {
            return true
        }
        return false
    }

    private func runtimeProbe(_ runtime: CoreSimulatorRuntimeProbe, matches configured: String) -> Bool {
        if let identifier = trimmedNonEmpty(runtime.identifier),
           CoreSimulatorRuntime.matches(identifier, configured) {
            return true
        }
        if let name = trimmedNonEmpty(runtime.name),
           CoreSimulatorRuntime.matches(name, configured) {
            return true
        }
        return false
    }

    private func isCoreSimulatorIdentifier(_ value: String, prefix: String) -> Bool {
        value.lowercased().hasPrefix(prefix.lowercased())
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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

}

private struct ManagedSimulatorCreateReferences {
    var deviceType: String
    var runtime: String
}

private struct SimctlDeviceTypeList: Decodable {
    var devicetypes: [SimctlDeviceType]
}

private struct SimctlDeviceType: Decodable {
    var name: String?
    var identifier: String?
}

private struct SimctlDeviceList: Decodable {
    var devices: [String: [SimctlDevice]]
}

private struct SimctlDevice: Decodable {
    var name: String?
    var udid: String?
    var state: String?
    var deviceTypeIdentifier: String?
    var isAvailable: Bool?
    var availability: String?
    var availabilityError: String?

    enum CodingKeys: String, CodingKey {
        case name
        case udid
        case state
        case deviceTypeIdentifier
        case deviceType
        case deviceTypeSnakeCase = "device_type"
        case isAvailable
        case availability
        case availabilityError
        case availabilityErrorSnakeCase = "availability_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        udid = try container.decodeIfPresent(String.self, forKey: .udid)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        deviceTypeIdentifier = try container.decodeIfPresent(String.self, forKey: .deviceTypeIdentifier)
            ?? (try container.decodeIfPresent(String.self, forKey: .deviceType))
            ?? (try container.decodeIfPresent(String.self, forKey: .deviceTypeSnakeCase))
        isAvailable = CoreSimulatorAvailability.decodeFlag(from: container, forKey: .isAvailable)
        availability = try container.decodeIfPresent(String.self, forKey: .availability)
        availabilityError = try container.decodeIfPresent(String.self, forKey: .availabilityError)
            ?? (try container.decodeIfPresent(String.self, forKey: .availabilityErrorSnakeCase))
    }

    var isAvailableForUse: Bool {
        if isAvailable == false {
            return false
        }
        if let availabilityError, !availabilityError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if let availability,
           CoreSimulatorAvailability.textIndicatesUnavailable(availability) {
            return false
        }
        if let state, state.localizedCaseInsensitiveContains("unavailable") {
            return false
        }
        return true
    }

    func matchesConfiguredDeviceType(_ configuredDeviceType: String) -> Bool {
        guard let deviceTypeIdentifier = trimmedDeviceTypeIdentifier else {
            return true
        }
        return CoreSimulatorDeviceType.matches(deviceTypeIdentifier, configuredDeviceType)
    }

    func hasKnownMatchingDeviceType(_ configuredDeviceType: String) -> Bool {
        guard let deviceTypeIdentifier = trimmedDeviceTypeIdentifier else {
            return false
        }
        return CoreSimulatorDeviceType.matches(deviceTypeIdentifier, configuredDeviceType)
    }

    private var trimmedDeviceTypeIdentifier: String? {
        guard let value = deviceTypeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct ManagedSimulatorCandidate {
    var runtime: String
    var udid: String
    var hasKnownMatchingDeviceType: Bool
}
