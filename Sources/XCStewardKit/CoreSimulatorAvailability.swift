// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

enum CoreSimulatorAvailability {
    static func flag(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.intValue != 0
        }
        guard let string = value as? String else {
            return nil
        }

        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            if textIndicatesUnavailable(string) {
                return false
            }
            if textIndicatesAvailable(string) {
                return true
            }
            return nil
        }
    }

    static func decodeFlag<Key: CodingKey>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> Bool? {
        if let bool = try? container.decode(Bool.self, forKey: key) {
            return bool
        }
        if let int = try? container.decode(Int.self, forKey: key) {
            return int != 0
        }
        guard let string = try? container.decode(String.self, forKey: key) else {
            return nil
        }
        return flag(string)
    }

    static func textIndicatesUnavailable(_ text: String) -> Bool {
        let words = availabilityWords(text)
        if words.contains("unavailable") {
            return true
        }
        for pair in zip(words, words.dropFirst()) {
            if (pair.0 == "not" || pair.0 == "no") && pair.1 == "available" {
                return true
            }
        }
        return false
    }

    static func textIndicatesAvailable(_ text: String) -> Bool {
        let words = availabilityWords(text)
        return !textIndicatesUnavailable(text) && words.contains("available")
    }

    private static func availabilityWords(_ text: String) -> [String] {
        text
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0).lowercased() }
    }
}
