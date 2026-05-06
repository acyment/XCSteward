import Foundation
import XCStewardKit

var arguments = CommandLine.arguments
let wantsJSON = arguments.contains("--json")
let stateRoot = resolveStateRoot(arguments: &arguments, environment: ProcessInfo.processInfo.environment)
var app = XCStewardApp(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))

do {
    let exitCode = try app.run(arguments: CommandLine.arguments)
    exit(exitCode)
} catch {
    if wantsJSON {
        writeJSONError(error)
    } else {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
    }
    exit(1)
}

private struct CommandErrorEnvelope: Encodable {
    var error: CommandErrorPayload
}

private struct CommandErrorPayload: Encodable {
    var code: String
    var message: String
}

private func writeJSONError(_ error: Error) {
    let payload = CommandErrorEnvelope(
        error: CommandErrorPayload(
            code: errorCode(for: error),
            message: String(describing: error)
        )
    )
    do {
        FileHandle.standardError.write(try jsonData(payload))
        FileHandle.standardError.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
    }
}

private func errorCode(for error: Error) -> String {
    guard let stewardError = error as? XCStewardError else {
        return "unexpected_error"
    }
    switch stewardError {
    case .usage:
        return "usage"
    case .notFound:
        return "not_found"
    case .invalidConfiguration:
        return "invalid_configuration"
    case .commandFailed:
        return "command_failed"
    case .canceled:
        return "canceled"
    }
}
