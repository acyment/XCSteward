// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation
import XCStewardKit

var arguments = CommandLine.arguments
let wantsJSON = arguments.contains("--json")
let initialStateRoot = defaultStateRoot(environment: ProcessInfo.processInfo.environment)
var app = XCStewardApp(environment: AppEnvironment(paths: AppPaths(stateRoot: initialStateRoot)))

do {
    let exitCode = try app.run(arguments: CommandLine.arguments)
    exit(exitCode)
} catch {
    if wantsJSON {
        writeJSONError(error)
    } else {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
    }
    exit(exitCode(for: error))
}

private struct CommandErrorEnvelope: Encodable {
    var error: CommandErrorPayload
    var schemaVersion: Int = xcstewardSchemaVersion

    enum CodingKeys: String, CodingKey {
        case error
        case schemaVersion = "schema_version"
    }
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
