import Foundation
import XCStewardKit

var arguments = CommandLine.arguments
let stateRoot = resolveStateRoot(arguments: &arguments, environment: ProcessInfo.processInfo.environment)
var app = XCStewardApp(environment: AppEnvironment(paths: AppPaths(stateRoot: stateRoot)))

do {
    let exitCode = try app.run(arguments: CommandLine.arguments)
    exit(exitCode)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
