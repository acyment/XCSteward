import Foundation

enum CoreSimulatorDeviceType {
    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "SimDeviceType.", options: [.caseInsensitive]) {
            return compact(trimmed[range.upperBound...])
        }

        let words = deviceTypeWords(trimmed)
        if let familyIndex = deviceFamilyIndex(in: words) {
            return words[familyIndex...].joined()
        }
        return words.joined()
    }

    static func matches(_ listedDeviceType: String, _ configuredDeviceType: String) -> Bool {
        listedDeviceType == configuredDeviceType || normalized(listedDeviceType) == normalized(configuredDeviceType)
    }

    private static func compact<S: StringProtocol>(_ value: S) -> String {
        String(value.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    private static func deviceTypeWords(_ value: String) -> [String] {
        value
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0).lowercased() }
    }

    private static func deviceFamilyIndex(in words: [String]) -> Int? {
        words.indices.first { index in
            let word = words[index]
            if word == "iphone" || word == "ipad" {
                return true
            }
            guard word == "apple" else {
                return false
            }
            let nextIndex = index + 1
            return words.indices.contains(nextIndex) &&
                ["tv", "watch", "vision"].contains(words[nextIndex])
        }
    }
}
