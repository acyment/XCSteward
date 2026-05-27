// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct HostCapacityParser: Sendable {
    func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed?.isEmpty == true ? nil : trimmed
    }

    func isConstrainedMemoryPressure(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["warn", "warning", "serious", "critical"].contains(value)
    }

    func parseMemoryPressure(_ output: String) -> String? {
        let normalized = output.lowercased()
        if normalized.contains("critical") {
            return "critical"
        }
        if normalized.contains("serious") {
            return "serious"
        }
        if normalized.contains("warning") || normalized.contains("warn") {
            return "warning"
        }
        if normalized.contains("normal") || normalized.contains("nominal") {
            return "normal"
        }
        return nil
    }

    func isConstrainedThermalState(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["serious", "critical"].contains(value)
    }

    func parseThermalState(_ output: String) -> String? {
        let normalized = output.lowercased()
        if normalized.contains("critical") {
            return "critical"
        }
        if normalized.contains("serious") {
            return "serious"
        }
        if normalized.contains("warning") || normalized.contains("warn") {
            return "serious"
        }
        if let cpuSpeedLimit = numericValue(after: "cpu_speed_limit", in: normalized) {
            if cpuSpeedLimit <= 50 {
                return "critical"
            }
            if cpuSpeedLimit < 80 {
                return "serious"
            }
            if cpuSpeedLimit < 100 {
                return "fair"
            }
            return "nominal"
        }
        if let warningLevel = numericValue(after: "thermal warning level", in: normalized) {
            if warningLevel >= 3 {
                return "critical"
            }
            if warningLevel >= 2 {
                return "serious"
            }
            if warningLevel >= 1 {
                return "fair"
            }
            return "nominal"
        }
        if normalized.contains("normal") || normalized.contains("nominal") {
            return "nominal"
        }
        return nil
    }

    func countBootedSimulators(in data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        var count = 0
        func walk(_ value: Any) {
            if let array = value as? [Any] {
                array.forEach(walk)
                return
            }
            guard let object = value as? [String: Any] else {
                return
            }
            if normalized(object["state"] as? String) == "booted" {
                count += 1
            }
            object.values.forEach(walk)
        }
        walk(json)
        return count
    }

    func normalizedForeignActivityPolicy(_ value: String?) -> String {
        switch normalized(value) {
        case "strict":
            return "strict"
        case "ignore":
            return "ignore"
        case "capacity", nil:
            return "capacity"
        default:
            return "capacity"
        }
    }

    func integer(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func bool(_ value: String?) -> Bool {
        guard let value = normalized(value) else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }

    func double(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func formatLoadAverage(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func numericValue(after marker: String, in output: String) -> Double? {
        guard let markerRange = output.range(of: marker) else {
            return nil
        }
        let suffix = output[markerRange.upperBound...]
        guard let start = suffix.firstIndex(where: { $0.isNumber }) else {
            return nil
        }
        let numberText = suffix[start...].prefix { $0.isNumber || $0 == "." }
        return Double(numberText)
    }
}
