import Foundation
import XCTest

struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum TestSupportError: Error {
    case executableNotFound
}

func productsDirectory() throws -> URL {
    #if os(macOS)
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        return bundle.bundleURL.deletingLastPathComponent()
    }
    #endif
    throw TestSupportError.executableNotFound
}

func executableURL() throws -> URL {
    try productsDirectory().appendingPathComponent("xcsteward")
}

@discardableResult
func runCLI(
    arguments: [String],
    environment: [String: String] = [:],
    currentDirectoryURL: URL? = nil
) throws -> CLIResult {
    let process = Process()
    process.executableURL = try executableURL()
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL
    var mergedEnvironment = ProcessInfo.processInfo.environment
    mergedEnvironment["XCSTEWARD_DOCTOR_MIN_FREE_BYTES"] = "0"
    mergedEnvironment["XCSTEWARD_DOCTOR_WARN_FREE_BYTES"] = "0"
    mergedEnvironment["XCSTEWARD_DOCTOR_WARN_FREE_PERCENT"] = "0"
    for (key, value) in environment {
        mergedEnvironment[key] = value
    }
    process.environment = mergedEnvironment

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    return CLIResult(
        status: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

func makeTempDirectory(function: String = #function) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("XCStewardTests")
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent(function)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    TestTempDirectoryTracker.shared.track(root)
    return root
}

func writeText(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func writeExecutable(_ text: String, to url: URL) throws {
    try writeText(text, to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

func parseJSON(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8))
}

func createProfile(name: String, stateRoot: URL, repoRoot: URL, body: String) throws {
    try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repoRoot.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
    try writeText(
        """
        repo_root = "\(repoRoot.path)"
        \(body)
        """,
        to: stateRoot.appendingPathComponent("projects/\(name).toml")
    )
}

func waitUntil(timeout: TimeInterval, pollInterval: TimeInterval = 0.1, condition: () throws -> Bool) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() {
            return true
        }
        Thread.sleep(forTimeInterval: pollInterval)
    }
    return try condition()
}

func seedStaleLease(stateRoot: URL) throws {
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    try writeText(
        """
        {"worker_id":"stale-worker","pid":999999,"heartbeat":1,"job_id":"ghost-job"}
        """,
        to: stateRoot.appendingPathComponent("stale-lease.json")
    )
}

private final class TestTempDirectoryTracker: NSObject, XCTestObservation, @unchecked Sendable {
    static let shared = TestTempDirectoryTracker()

    private let lock = NSLock()
    private var registered = false
    private var directories: [URL] = []

    func track(_ url: URL) {
        lock.lock()
        if !registered {
            XCTestObservationCenter.shared.addTestObserver(self)
            registered = true
        }
        directories.append(url)
        lock.unlock()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        cleanupTrackedDirectories()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        cleanupTrackedDirectories()
    }

    private func cleanupTrackedDirectories() {
        lock.lock()
        let pending = directories
        directories.removeAll()
        lock.unlock()

        for directory in pending {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
