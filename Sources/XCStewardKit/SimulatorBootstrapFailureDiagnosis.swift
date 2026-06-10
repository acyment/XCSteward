// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct SimulatorBootstrapFailureDiagnosis {
    static let preXCTestMessage = "The run failed before XCTest attached; this is an environment failure, not evidence of a code regression."

    static func matches(_ text: String) -> Bool {
        containsAny(text, patterns: bootstrapFailurePatterns)
    }

    static func summaryLine(errorDescription: String, simulatorID: String?) -> String? {
        guard matches(errorDescription) else {
            return nil
        }
        var parts = [preXCTestMessage]
        if let simulatorID = trimmedNonEmpty(simulatorID) {
            parts.append("Simulator bootstrap failed for \(simulatorID).")
        } else {
            parts.append("Simulator bootstrap failed.")
        }
        if let detail = compactDetail(errorDescription) {
            parts.append("Detail: \(detail)")
        }
        parts.append("Remediation: \(remediationHint(simulatorID: simulatorID))")
        return parts.joined(separator: " ")
    }

    static func preXCTestTimeoutSummaryLine(timeoutSeconds: TimeInterval?, simulatorID: String?) -> String {
        var parts = [
            "XCTest did not attach before the test command timed out; this is an environment/bootstrap failure, not a test case timeout.",
        ]
        if let timeoutSeconds {
            parts.append("Timeout: \(formattedSeconds(timeoutSeconds)).")
        }
        if let simulatorID = trimmedNonEmpty(simulatorID) {
            parts.append("Simulator: \(simulatorID).")
        }
        parts.append("Remediation: \(remediationHint(simulatorID: simulatorID))")
        return parts.joined(separator: " ")
    }

    static func remediationHint(simulatorID: String?) -> String {
        if let simulatorID = trimmedNonEmpty(simulatorID) {
            return "try `xcrun simctl shutdown \(simulatorID)` then `xcrun simctl erase \(simulatorID)` and retry once; if it repeats, run `xcsteward doctor --json` and inspect CoreSimulator diagnostics."
        }
        return "try shutting down or erasing the selected simulator and retry once; if it repeats, run `xcsteward doctor --json` and inspect CoreSimulator diagnostics."
    }

    private static func compactDetail(_ text: String) -> String? {
        let compact = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !compact.isEmpty else {
            return nil
        }
        if compact.count <= 700 {
            return compact
        }
        return "\(compact.prefix(700))..."
    }

    private static func containsAny(_ text: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            text.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func formattedSeconds(_ seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds {
            return "\(Int(seconds))s"
        }
        return String(format: "%.3fs", seconds)
    }

    static var bootstrapFailurePatterns: [String] {
        [
            "XCTest did not attach",
            "pre_xctest_timeout",
            "Unable to boot simulator",
            "Unable to boot the Simulator",
            "Unable to confirm simulator boot status",
            "launchd_sim",
            "launchd failed to respond",
            "Failed to start launchd_sim",
            "Failed to prepare device",
            "SimLaunchHostService",
            "NSPOSIXErrorDomain, code=60",
            "NSPOSIXErrorDomain code=60",
            "operation never finished bootstrapping",
            "Failed to background test runner",
            "Lost connection to testmanagerd",
            "Early unexpected exit",
            "before establishing connection",
            "Invalid connectionUUID",
            "Bad or unknown session",
            "CoreSimulatorService unavailable",
        ]
    }
}
