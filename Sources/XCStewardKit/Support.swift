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
    func removeItem(_ url: URL) throws
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
    public func removeItem(_ url: URL) throws {
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
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
}

public struct ToolResult {
    public let exitCode: Int32
    public let output: String
    public let timedOut: Bool
}

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
    public init() {}

    public func run(
        tool: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval?,
        processStarted: ((Int32) throws -> Void)? = nil
    ) throws -> ToolResult {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            merged[key] = value
        }
        let executable = try resolveExecutable(named: tool, environment: merged, workingDirectory: workingDirectory)

        let pipe = Pipe()

        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
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
            if let status = pollExitStatus(pid: pid) {
                waitForOutputDrain(readHandle: readHandle, readGroup: readGroup)
                return ToolResult(exitCode: exitCode(fromWaitStatus: status), output: String(data: collector.snapshot(), encoding: .utf8) ?? "", timedOut: false)
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
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
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

    private func pollExitStatus(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                return status
            }
            if result == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            return status
        }
    }

    private func waitForExit(pid: pid_t, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let status = pollExitStatus(pid: pid) {
                return status
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return pollExitStatus(pid: pid)
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
    case commandFailed(String)
    case canceled(String)

    public var description: String {
        switch self {
        case let .usage(message),
             let .notFound(message),
             let .invalidConfiguration(message),
             let .commandFailed(message),
             let .canceled(message):
            return message
        }
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
    if pid <= 0 { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

public func resolveStateRoot(arguments: inout [String], environment: [String: String]) -> URL {
    if let index = arguments.firstIndex(of: "--state-root"), arguments.indices.contains(index + 1) {
        let path = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
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

public func consumeOption(_ option: String, from arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
        return nil
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}
