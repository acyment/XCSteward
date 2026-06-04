// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import Dispatch
import Darwin

public struct AppPaths {
    public let stateRoot: URL
    public let dbURL: URL
    public let jobsRoot: URL
    public let projectsRoot: URL
    public let doctorRoot: URL

    public init(stateRoot: URL) {
        self.stateRoot = stateRoot
        self.dbURL = stateRoot.appendingPathComponent("state.db")
        self.jobsRoot = stateRoot.appendingPathComponent("jobs")
        self.projectsRoot = stateRoot.appendingPathComponent("projects")
        self.doctorRoot = stateRoot.appendingPathComponent("doctor")
    }
}

public protocol Clock {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public protocol UUIDProviding {
    func makeUUID() -> String
}

public struct SystemUUIDProvider: UUIDProviding {
    public init() {}
    public func makeUUID() -> String { UUID().uuidString.lowercased() }
}

public protocol ProcessInfoProviding {
    var environment: [String: String] { get }
    var arguments: [String] { get }
}

public struct SystemProcessInfo: ProcessInfoProviding {
    public init() {}
    public var environment: [String: String] { ProcessInfo.processInfo.environment }
    public var arguments: [String] { CommandLine.arguments }
}

public protocol FileSystem {
    func createDirectory(_ url: URL) throws
    func writeData(_ data: Data, to url: URL) throws
    func appendData(_ data: Data, to url: URL) throws
    func readData(from url: URL) throws -> Data
    func fileExists(_ url: URL) -> Bool
    func isRegularFile(_ url: URL) -> Bool
    func removeItem(_ url: URL) throws
    func moveItem(_ source: URL, to destination: URL) throws
    func contentsOfDirectory(_ url: URL) throws -> [URL]
}

public struct LocalFileSystem: FileSystem {
    private let manager = FileManager.default
    public init() {}
    public func createDirectory(_ url: URL) throws {
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
    }
    public func writeData(_ data: Data, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        try data.write(to: url)
    }
    public func appendData(_ data: Data, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
    public func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
    public func fileExists(_ url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }
    public func isRegularFile(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return true
    }
    public func removeItem(_ url: URL) throws {
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
    }
    public func moveItem(_ source: URL, to destination: URL) throws {
        try createDirectory(destination.deletingLastPathComponent())
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: source, to: destination)
    }
    public func contentsOfDirectory(_ url: URL) throws -> [URL] {
        try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}

public protocol ToolRunning {
    @discardableResult
    func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)?
    ) throws -> ToolResult

    @discardableResult
    func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)?,
        shouldTerminate: (() throws -> Bool)?
    ) throws -> ToolResult
}

public extension ToolRunning {
    @discardableResult
    func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?
    ) throws -> ToolResult {
        try run(
            tool: tool,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout,
            processStarted: nil
        )
    }

    @discardableResult
    func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)?,
        shouldTerminate: (() throws -> Bool)?
    ) throws -> ToolResult {
        try run(
            tool: tool,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout,
            processStarted: processStarted
        )
    }
}

public struct ToolResult {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool
}

typealias WaitPIDFunction = (pid_t, UnsafeMutablePointer<Int32>?, Int32) -> pid_t

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public final class ProcessToolRunner: ToolRunning {
    private let waitPID: WaitPIDFunction

    public init() {
        self.waitPID = Darwin.waitpid
    }

    init(waitPID: @escaping WaitPIDFunction) {
        self.waitPID = waitPID
    }

    public func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)? = nil
    ) throws -> ToolResult {
        try run(
            tool: tool,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout,
            processStarted: processStarted,
            shouldTerminate: nil
        )
    }

    public func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)?,
        shouldTerminate: (() throws -> Bool)?
    ) throws -> ToolResult {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            merged[key] = value
        }
        let executable = try resolveExecutable(named: tool, environment: merged, workingDirectory: workingDirectory)

        let pipe = Pipe()

        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        try setCloseOnExec(readHandle.fileDescriptor)
        try setCloseOnExec(writeHandle.fileDescriptor)
        let readGroup = DispatchGroup()
        let readQueue = DispatchQueue(label: "XCSteward.ProcessToolRunner.output")
        let collector = OutputCollector()
        readGroup.enter()
        readQueue.async {
            while true {
                let data = readHandle.availableData
                if data.isEmpty {
                    break
                }
                collector.append(data)
            }
            readGroup.leave()
        }

        let pid = try spawnProcessGroup(
            executable: executable,
            arguments: arguments,
            environment: merged,
            workingDirectory: workingDirectory,
            outputDescriptor: writeHandle.fileDescriptor
        )
        try? writeHandle.close()
        do {
            try processStarted?(pid)
        } catch {
            _ = terminateProcessGroup(pid: pid, readHandle: readHandle, readGroup: readGroup)
            throw error
        }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            do {
                if let status = try pollExitStatus(pid: pid) {
                    waitForOutputDrain(readHandle: readHandle, readGroup: readGroup)
                    return ToolResult(exitCode: exitCode(fromWaitStatus: status), output: String(data: collector.snapshot(), encoding: .utf8) ?? "", timedOut: false)
                }
            } catch {
                _ = terminateProcessGroup(pid: pid, readHandle: readHandle, readGroup: readGroup)
                throw error
            }
            if try shouldTerminate?() == true {
                let status = terminateProcessGroup(pid: pid, readHandle: readHandle, readGroup: readGroup)
                return ToolResult(exitCode: status.map(exitCode(fromWaitStatus:)) ?? 128 + SIGTERM, output: String(data: collector.snapshot(), encoding: .utf8) ?? "", timedOut: false)
            }
            if let deadline, Date() > deadline {
                let status = terminateProcessGroup(pid: pid, readHandle: readHandle, readGroup: readGroup)
                return ToolResult(exitCode: status.map(exitCode(fromWaitStatus:)) ?? SIGKILL, output: String(data: collector.snapshot(), encoding: .utf8) ?? "", timedOut: true)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func spawnProcessGroup(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        outputDescriptor: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        configureFileActions(&fileActions, outputDescriptor: outputDescriptor, workingDirectory: workingDirectory)
        configureProcessGroup(&attributes)

        let argvStrings = [executable.path] + arguments
        let envStrings = environment.map { "\($0.key)=\($0.value)" }
        var argv = makeCStringArray(argvStrings)
        var envp = makeCStringArray(envStrings)
        defer {
            freeCStringArray(argv)
            freeCStringArray(envp)
        }

        var pid: pid_t = 0
        let result = executable.path.withCString { pathPointer in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                envp.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(
                        &pid,
                        pathPointer,
                        &fileActions,
                        &attributes,
                        argvBuffer.baseAddress,
                        envBuffer.baseAddress
                    )
                }
            }
        }
        guard result == 0 else {
            throw XCStewardError.commandFailed("Unable to launch \(executable.path): \(String(cString: strerror(result)))")
        }
        return pid
    }

    private func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0 else {
            throw XCStewardError.commandFailed("Unable to inspect file descriptor flags: \(String(cString: strerror(errno)))")
        }
        guard fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw XCStewardError.commandFailed("Unable to mark file descriptor close-on-exec: \(String(cString: strerror(errno)))")
        }
    }

    private func configureFileActions(
        _ fileActions: inout posix_spawn_file_actions_t?,
        outputDescriptor: Int32,
        workingDirectory: URL?
    ) {
        posix_spawn_file_actions_adddup2(&fileActions, outputDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, outputDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, outputDescriptor)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path)
        }
    }

    private func configureProcessGroup(_ attributes: inout posix_spawnattr_t?) {
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
    }

    private func makeCStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var cStrings = strings.map { strdup($0) }
        cStrings.append(nil)
        return cStrings
    }

    private func freeCStringArray(_ cStrings: [UnsafeMutablePointer<CChar>?]) {
        cStrings.compactMap { $0 }.forEach { free($0) }
    }

    private func terminateProcessGroup(pid: pid_t, readHandle: FileHandle, readGroup: DispatchGroup) -> Int32? {
        sendSignal(SIGTERM, toProcessGroupFor: pid)
        var status = waitForExit(pid: pid, timeout: 1)
        if status == nil {
            sendSignal(SIGKILL, toProcessGroupFor: pid)
            status = waitForExit(pid: pid, timeout: 1)
        }
        waitForOutputDrain(readHandle: readHandle, readGroup: readGroup)
        return status
    }

    private func sendSignal(_ signal: Int32, toProcessGroupFor pid: pid_t) {
        if kill(-pid, signal) != 0 {
            kill(pid, signal)
        }
    }

    private func pollExitStatus(pid: pid_t) throws -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitPID(pid, &status, WNOHANG)
            if result == pid {
                return status
            }
            if result == 0 {
                return nil
            }
            let waitError = errno
            if waitError == EINTR {
                continue
            }
            throw XCStewardError.commandFailed("Unable to monitor process \(pid): \(String(cString: strerror(waitError)))")
        }
    }

    private func waitForExit(pid: pid_t, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let status = try? pollExitStatus(pid: pid) else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            return status
        }
        return try? pollExitStatus(pid: pid)
    }

    private func waitForOutputDrain(readHandle: FileHandle, readGroup: DispatchGroup) {
        if readGroup.wait(timeout: .now() + 1) == .timedOut {
            try? readHandle.close()
            _ = readGroup.wait(timeout: .now() + 1)
        }
    }

    private func exitCode(fromWaitStatus status: Int32) -> Int32 {
        if waitStatus(status) == 0 {
            return (status >> 8) & 0x000000ff
        }
        if waitStatus(status) != 0o177 {
            return 128 + waitStatus(status)
        }
        return status
    }

    private func waitStatus(_ status: Int32) -> Int32 {
        status & 0o177
    }

    private func resolveExecutable(named tool: String, environment: [String: String], workingDirectory: URL?) throws -> URL {
        if tool.contains("/") {
            if let workingDirectory {
                return URL(fileURLWithPath: tool, relativeTo: workingDirectory).standardizedFileURL
            }
            return URL(fileURLWithPath: tool).standardizedFileURL
        }

        let searchPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for path in searchPaths {
            let candidate = URL(fileURLWithPath: path).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw XCStewardError.commandFailed("Unable to resolve executable for \(tool)")
    }
}

public struct AppEnvironment {
    public var paths: AppPaths
    public var fileSystem: FileSystem
    public var clock: Clock
    public var uuidProvider: UUIDProviding
    public var processInfo: ProcessInfoProviding
    public var toolRunner: ToolRunning

    public init(
        paths: AppPaths,
        fileSystem: FileSystem = LocalFileSystem(),
        clock: Clock = SystemClock(),
        uuidProvider: UUIDProviding = SystemUUIDProvider(),
        processInfo: ProcessInfoProviding = SystemProcessInfo(),
        toolRunner: ToolRunning = ProcessToolRunner()
    ) {
        self.paths = paths
        self.fileSystem = fileSystem
        self.clock = clock
        self.uuidProvider = uuidProvider
        self.processInfo = processInfo
        self.toolRunner = toolRunner
    }
}

public enum XCStewardError: Error, CustomStringConvertible {
    case usage(String)
    case notFound(String)
    case invalidConfiguration(String)
    case stateRootUnavailable(String)
    case commandFailed(String)
    case canceled(String)

    public var description: String {
        switch self {
        case let .usage(message),
             let .notFound(message),
             let .invalidConfiguration(message),
             let .stateRootUnavailable(message),
             let .commandFailed(message),
             let .canceled(message):
            return message
        }
    }
}

/// Version of the machine-readable JSON contract emitted on stdout/stderr.
/// Bump ONLY on breaking changes (removed/renamed/retyped field, changed enum
/// meaning, or changed exit-code meaning). Additive changes do not bump it.
/// See CONTRACT.md.
public let xcstewardSchemaVersion = 1

/// Stable process exit codes. `0` = success; everything else is a failure.
/// Documented in CONTRACT.md. Ranges: 1 generic, 2-9 CLI/usage errors,
/// 10-19 job outcomes, 20-29 command diagnostics, 30+ reserved.
public enum ExitCode {
    public static let success: Int32 = 0
    public static let generic: Int32 = 1
    public static let usage: Int32 = 2
    public static let notFound: Int32 = 3
    public static let invalidConfiguration: Int32 = 4
    public static let stateRootUnavailable: Int32 = 5
    public static let canceled: Int32 = 6 // operation aborted (XCStewardError.canceled)
    public static let commandFailed: Int32 = 7
    public static let testFailure: Int32 = 10 // test_failure / build_failure
    public static let testTimeout: Int32 = 11 // test_timeout / build_timeout
    public static let infraFailure: Int32 = 12 // runner_bootstrap / artifact failure
    public static let jobCanceled: Int32 = 13 // terminal job canceled
    public static let internalError: Int32 = 14 // internal_error / unsupported_destination
    public static let doctorFailed: Int32 = 20
}

/// Stable string code for an error (mirrors the exit code; emitted in the
/// `--json` error envelope). Keep these strings stable — they are part of the
/// contract and asserted by tests.
public func errorCode(for error: Error) -> String {
    guard let stewardError = error as? XCStewardError else {
        return "unexpected_error"
    }
    switch stewardError {
    case .usage: return "usage"
    case .notFound: return "not_found"
    case .invalidConfiguration: return "invalid_configuration"
    case .stateRootUnavailable: return "state_root_unavailable"
    case .commandFailed: return "command_failed"
    case .canceled: return "canceled"
    }
}

/// Process exit code for a thrown error (see CONTRACT.md exit-code table).
public func exitCode(for error: Error) -> Int32 {
    guard let stewardError = error as? XCStewardError else {
        return ExitCode.generic
    }
    switch stewardError {
    case .usage: return ExitCode.usage
    case .notFound: return ExitCode.notFound
    case .invalidConfiguration: return ExitCode.invalidConfiguration
    case .stateRootUnavailable: return ExitCode.stateRootUnavailable
    case .commandFailed: return ExitCode.commandFailed
    case .canceled: return ExitCode.canceled
    }
}

/// Process exit code for a job's terminal outcome (used by submit --wait and
/// status). Non-terminal jobs are not a failure → `0`.
public func exitCode(for resultClass: ResultClass?, state: JobState) -> Int32 {
    guard state.isTerminal else { return ExitCode.success }
    guard let resultClass else {
        switch state {
        case .succeeded: return ExitCode.success
        case .canceled: return ExitCode.jobCanceled
        default: return ExitCode.generic
        }
    }
    switch resultClass {
    case .success: return ExitCode.success
    case .testFailure, .buildFailure: return ExitCode.testFailure
    case .testTimeout, .buildTimeout: return ExitCode.testTimeout
    case .runnerBootstrapFailure, .artifactFailure: return ExitCode.infraFailure
    case .canceled: return ExitCode.jobCanceled
    case .internalError, .unsupportedDestination: return ExitCode.internalError
    }
}

public func defaultStateRoot(environment: [String: String]) -> URL {
    if let custom = environment["XCSTEWARD_HOME"], !custom.isEmpty {
        return URL(fileURLWithPath: custom)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Application Support/XCSteward")
}

public func jsonData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
}

public func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
}

public func isPIDAlive(_ pid: Int32) -> Bool {
    guard pid > 0 else {
        return false
    }
    guard kill(pid, 0) == 0 || errno == EPERM else {
        return false
    }
    return !isPIDZombie(pid)
}

private func isPIDZombie(_ pid: Int32) -> Bool {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
    guard result == Int32(size) else {
        return false
    }
    return info.pbi_status == SZOMB
}

public func resolveStateRoot(arguments: inout [String], environment: [String: String]) throws -> URL {
    if let index = arguments.firstIndex(of: "--state-root") {
        let valueIndex = index + 1
        guard arguments.indices.contains(valueIndex),
              !isOptionToken(arguments[valueIndex]) else {
            throw XCStewardError.usage("Option --state-root requires a value")
        }
        let path = arguments[valueIndex]
        arguments.removeSubrange(index...valueIndex)
        return URL(fileURLWithPath: path)
    }
    return defaultStateRoot(environment: environment)
}

public func removeFlag(_ flag: String, from arguments: inout [String]) -> Bool {
    if let index = arguments.firstIndex(of: flag) {
        arguments.remove(at: index)
        return true
    }
    return false
}

public func consumeOption(_ option: String, from arguments: inout [String]) throws -> String? {
    guard let index = arguments.firstIndex(of: option) else {
        return nil
    }
    let valueIndex = index + 1
    guard arguments.indices.contains(valueIndex),
          !isOptionToken(arguments[valueIndex]) else {
        throw XCStewardError.usage("Option \(option) requires a value")
    }
    let value = arguments[valueIndex]
    arguments.removeSubrange(index...valueIndex)
    return value
}

private func isOptionToken(_ argument: String) -> Bool {
    argument.hasPrefix("--") || argument == "-h"
}
