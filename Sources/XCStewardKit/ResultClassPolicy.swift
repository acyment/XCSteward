import Foundation

struct ResultClassPolicy: Sendable {
    func terminalState(for resultClass: ResultClass) -> JobState {
        switch resultClass {
        case .success:
            return .succeeded
        case .canceled:
            return .canceled
        case .buildFailure, .buildTimeout, .testFailure, .testTimeout, .unsupportedDestination, .runnerBootstrapFailure, .artifactFailure, .internalError:
            return .failed
        }
    }

    func summaryLine(for resultClass: ResultClass) -> String {
        switch resultClass {
        case .success:
            return "Tests succeeded"
        case .buildFailure:
            return "Build failed"
        case .buildTimeout:
            return "Build timed out"
        case .runnerBootstrapFailure:
            return "Runner failed before tests executed"
        case .artifactFailure:
            return "Artifacts were missing or invalid"
        case .testTimeout:
            return "Tests timed out"
        case .unsupportedDestination:
            return "Destination is unsupported"
        case .testFailure:
            return "Tests failed"
        case .canceled:
            return "Canceled"
        case .internalError:
            return "Internal error"
        }
    }

    func junitErrorMessage(for resultClass: ResultClass) -> String? {
        switch resultClass {
        case .runnerBootstrapFailure, .artifactFailure, .testTimeout, .unsupportedDestination, .canceled, .internalError, .buildFailure, .buildTimeout:
            return summaryLine(for: resultClass)
        case .success, .testFailure:
            return nil
        }
    }
}
