import Foundation

enum DoctorOutputParsers {
    static func showDestinationsOutputExposesIOSSimulator(_ output: String) -> Bool {
        for fields in availableDestinationFields(from: output) where isIOSSimulatorDestination(fields) {
            if !isPlaceholderDestination(fields) {
                return true
            }
        }
        return false
    }

    static func showDestinationsOutputExposesOnlyIOSSimulatorPlaceholder(_ output: String) -> Bool {
        var hasIOSSimulatorPlaceholder = false
        var hasConcreteIOSSimulator = false
        for fields in availableDestinationFields(from: output) where isIOSSimulatorDestination(fields) {
            if isPlaceholderDestination(fields) {
                hasIOSSimulatorPlaceholder = true
            } else {
                hasConcreteIOSSimulator = true
            }
        }
        return hasIOSSimulatorPlaceholder && !hasConcreteIOSSimulator
    }

    static func showDestinationsOutputExposesMacOSDestination(_ output: String) -> Bool {
        availableDestinationFields(from: output).contains { fields in
            fields["platform"]?.caseInsensitiveCompare("macOS") == .orderedSame
        }
    }

    static func firstConcreteIOSSimulatorDestinationSpecifier(from output: String) -> String? {
        for fields in availableDestinationFields(from: output) where isIOSSimulatorDestination(fields) {
            guard !isPlaceholderDestination(fields),
                  let id = fields["id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else {
                continue
            }
            return "id=\(id)"
        }
        return nil
    }

    static func showsSDKsOutputExposesIPhoneSimulatorSDK(_ output: String) -> Bool {
        !iPhoneSimulatorSDKVersions(fromShowsdksOutput: output).isEmpty
    }

    static func iPhoneSimulatorSDKVersions(fromShowsdksOutput output: String) -> Set<String> {
        var versions: Set<String> = []
        let tokens = output
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        for (index, token) in tokens.enumerated() where token == "-sdk" {
            let valueIndex = index + 1
            guard tokens.indices.contains(valueIndex) else {
                continue
            }
            if let version = iPhoneSimulatorSDKVersion(from: tokens[valueIndex]) {
                versions.insert(version)
            }
        }
        for token in tokens {
            if token.lowercased().hasPrefix("-sdk=iphonesimulator"),
               let version = iPhoneSimulatorSDKVersion(from: token.dropFirst("-sdk=".count)) {
                versions.insert(version)
            }
        }
        return versions
    }

    static func normalizedVersion(from text: String) -> String? {
        var current = ""
        for character in text {
            if character.isNumber || character == "." || character == "-" {
                current.append(character == "-" ? "." : character)
            } else if let version = normalizedVersion(fromCandidate: current) {
                return version
            } else {
                current = ""
            }
        }
        return normalizedVersion(fromCandidate: current)
    }

    private static func availableDestinationFields(from output: String) -> [[String: String]] {
        var destinations: [[String: String]] = []
        var inIneligibleSection = false
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()
            if lowercased.hasPrefix("available destinations") {
                inIneligibleSection = false
                continue
            }
            if lowercased.hasPrefix("ineligible destinations") {
                inIneligibleSection = true
                continue
            }
            if inIneligibleSection {
                continue
            }
            guard let fields = destinationFields(inLine: line) else {
                continue
            }
            destinations.append(fields)
        }
        return destinations
    }

    private static func isPlaceholderDestination(_ fields: [String: String]) -> Bool {
        let id = fields["id"]?.lowercased() ?? ""
        let name = fields["name"]?.lowercased() ?? ""
        return id.contains("placeholder") || name == "any ios simulator device"
    }

    private static func isIOSSimulatorDestination(_ fields: [String: String]) -> Bool {
        fields["platform"]?.caseInsensitiveCompare("iOS Simulator") == .orderedSame
    }

    private static func iPhoneSimulatorSDKVersion(from token: some StringProtocol) -> String? {
        let lowercased = token.lowercased()
        guard lowercased.hasPrefix("iphonesimulator") else {
            return nil
        }
        return normalizedVersion(fromCandidate: String(lowercased.dropFirst("iphonesimulator".count)))
    }

    private static func normalizedVersion(fromCandidate candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        let parts = trimmed
            .split(separator: ".")
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        guard let major = parts.first else {
            return nil
        }
        let minor = parts.dropFirst().first ?? "0"
        return "\(major).\(minor)"
    }

    private static func destinationFields(inLine line: Substring) -> [String: String]? {
        guard let open = line.firstIndex(of: "{"),
              let close = line.lastIndex(of: "}"),
              open < close else {
            return nil
        }
        return destinationFields(in: line[line.index(after: open)..<close])
    }

    private static func destinationFields(in destination: Substring) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in destinationPairs(in: destination) {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                continue
            }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else {
                continue
            }
            fields[key] = value
        }
        return fields
    }

    private static func destinationPairs(in destination: Substring) -> [String] {
        let text = String(destination)
        var pairs: [String] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == ",", startsDestinationField(after: text.index(after: index), in: text) {
                pairs.append(String(text[start..<index]))
                start = text.index(after: index)
            }
            index = text.index(after: index)
        }
        if start < text.endIndex {
            pairs.append(String(text[start...]))
        }
        return pairs
    }

    private static func startsDestinationField(after index: String.Index, in text: String) -> Bool {
        var cursor = index
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
        let keyStart = cursor
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == ":" {
                return isDestinationFieldKey(String(text[keyStart..<cursor]))
            }
            if character == "," {
                return false
            }
            cursor = text.index(after: cursor)
        }
        return false
    }

    private static func isDestinationFieldKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        return trimmed.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_"
        }
    }
}
