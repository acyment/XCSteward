import Foundation

enum DoctorOutputParsers {
    static func showDestinationsOutputExposesIOSSimulator(_ output: String) -> Bool {
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
            guard let open = line.firstIndex(of: "{"),
                  let close = line.lastIndex(of: "}"),
                  open < close else {
                continue
            }
            let fields = destinationFields(in: line[line.index(after: open)..<close])
            if fields["platform"]?.caseInsensitiveCompare("iOS Simulator") == .orderedSame {
                return true
            }
        }
        return false
    }

    static func showsSDKsOutputExposesIPhoneSimulatorSDK(_ output: String) -> Bool {
        let tokens = output
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        for (index, token) in tokens.enumerated() where token == "-sdk" {
            let valueIndex = index + 1
            guard tokens.indices.contains(valueIndex) else {
                continue
            }
            if tokens[valueIndex].lowercased().hasPrefix("iphonesimulator") {
                return true
            }
        }
        for token in tokens {
            if token.lowercased().hasPrefix("-sdk=iphonesimulator") {
                return true
            }
        }
        return false
    }

    private static func destinationFields(in destination: Substring) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in destination.split(separator: ",") {
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
}
