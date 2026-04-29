import Foundation

struct ResultClassPolicy: Sendable {
    func terminalState(for resultClass: ResultClass) -> JobState {
        switch resultClass {
        case .success:
            return .succeeded
        case .canceled:
            return .canceled
        case .buildFailure, .testFailure, .testTimeout, .runnerBootstrapFailure, .artifactFailure, .internalError:
            return .failed
        }
    }

    func summaryLine(for resultClass: ResultClass) -> String {
        switch resultClass {
        case .success:
            return "Tests succeeded"
        case .buildFailure:
            return "Build failed"
        case .runnerBootstrapFailure:
            return "Runner failed before tests executed"
        case .artifactFailure:
            return "Artifacts were missing or invalid"
        case .testTimeout:
            return "Tests timed out"
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
        case .runnerBootstrapFailure, .artifactFailure, .testTimeout, .canceled, .internalError, .buildFailure:
            return summaryLine(for: resultClass)
        case .success, .testFailure:
            return nil
        }
    }
}
