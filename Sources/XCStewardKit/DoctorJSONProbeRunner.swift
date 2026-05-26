import Foundation

enum DoctorProbeFailure: Error {
    case timedOut
    case nonZeroExit
    case invalidJSON
}

struct DoctorJSONProbeRunner {
    let environment: AppEnvironment

    func runSimulatorRuntimesProbe() throws -> Result<[CoreSimulatorRuntimeProbe], DoctorProbeFailure> {
        switch try runDecodableJSONProbe(
            CoreSimulatorRuntimeListProbe.self,
            tool: "xcrun",
            arguments: ["simctl", "list", "runtimes", "--json"],
            timeout: 10
        ) {
        case .success(let probe):
            return .success(probe.runtimes)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func runDecodableJSONProbe<T: Decodable>(
        _ type: T.Type,
        tool: String,
        arguments: [String],
        environment environmentOverrides: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: TimeInterval
    ) throws -> Result<T, DoctorProbeFailure> {
        let result = try environment.toolRunner.run(
            tool: tool,
            arguments: arguments,
            environment: environmentOverrides,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        if result.timedOut {
            return .failure(.timedOut)
        }
        guard result.exitCode == 0 else {
            return .failure(.nonZeroExit)
        }
        guard let data = result.output.data(using: .utf8) else {
            return .failure(.invalidJSON)
        }
        do {
            return .success(try JSONDecoder().decode(type, from: data))
        } catch {
            return .failure(.invalidJSON)
        }
    }

    func runJSONProbe(
        tool: String,
        arguments: [String],
        environment environmentOverrides: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: TimeInterval
    ) throws -> Result<[String: Any], DoctorProbeFailure> {
        let result = try environment.toolRunner.run(
            tool: tool,
            arguments: arguments,
            environment: environmentOverrides,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        if result.timedOut {
            return .failure(.timedOut)
        }
        guard result.exitCode == 0 else {
            return .failure(.nonZeroExit)
        }
        guard let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        return .success(json)
    }
}
