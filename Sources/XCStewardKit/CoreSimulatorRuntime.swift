// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

enum CoreSimulatorRuntime {
    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "SimRuntime.", options: [.caseInsensitive]) {
            return compact(trimmed[range.upperBound...])
        }

        let words = runtimeWords(trimmed)
        if let platformIndex = words.firstIndex(where: isRuntimePlatformWord) {
            return words[platformIndex...].joined()
        }
        return words.joined()
    }

    static func matches(_ listedRuntime: String, _ configuredRuntime: String) -> Bool {
        listedRuntime == configuredRuntime || normalized(listedRuntime) == normalized(configuredRuntime)
    }

    static func isIOSRuntime(identifier: String?, name: String?) -> Bool {
        if let identifier {
            let lowered = identifier.lowercased()
            if lowered.contains(".ios-") || normalized(identifier).hasPrefix("ios") {
                return true
            }
        }
        if let name, normalized(name).hasPrefix("ios") {
            return true
        }
        return false
    }

    private static func compact<S: StringProtocol>(_ value: S) -> String {
        String(value.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    private static func runtimeWords(_ value: String) -> [String] {
        value
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0).lowercased() }
    }

    private static func isRuntimePlatformWord(_ word: String) -> Bool {
        switch word {
        case "ios", "tvos", "watchos", "visionos":
            return true
        default:
            return false
        }
    }
}
