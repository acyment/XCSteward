// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct ManualShardSimulatorPlan: Sendable {
    var configuredSimulatorIDs: [String]
    var requiredCount: Int

    var hasEnoughConfiguredSimulators: Bool {
        configuredSimulatorIDs.count >= requiredCount
    }

    var cloneDeficit: Int {
        max(0, requiredCount - configuredSimulatorIDs.count)
    }
}

struct ManualShardSimulatorSelection: Sendable {
    var simulatorIDs: [String]
    var transientSimulatorIDs: [String]
    var primaryNeedsBoot: Bool
}

struct ManualShardPlanner: Sendable {
    func simulatorPlan(
        primarySimulatorID: String,
        requestedSimulatorID: String?,
        defaultSimulatorID: String?,
        allowedSimulatorIDs: [String],
        requiredCount: Int
    ) -> ManualShardSimulatorPlan {
        var candidates: [String?] = [primarySimulatorID]
        candidates.append(requestedSimulatorID)
        candidates.append(defaultSimulatorID)
        candidates.append(contentsOf: allowedSimulatorIDs.map(Optional.some))
        return ManualShardSimulatorPlan(
            configuredSimulatorIDs: uniqueNonEmptyStrings(candidates),
            requiredCount: max(0, requiredCount)
        )
    }

    func configuredSimulatorSelection(from plan: ManualShardSimulatorPlan) -> ManualShardSimulatorSelection? {
        guard plan.hasEnoughConfiguredSimulators else {
            return nil
        }
        return ManualShardSimulatorSelection(
            simulatorIDs: Array(plan.configuredSimulatorIDs.prefix(plan.requiredCount)),
            transientSimulatorIDs: [],
            primaryNeedsBoot: false
        )
    }

    func filterEnumeratedTestIdentifiers(
        _ identifiers: [String],
        skipTesting: [String],
        matchesSkipFilter: (String, String) -> Bool
    ) -> [String] {
        identifiers.filter { identifier in
            !skipTesting.contains { skip in
                matchesSkipFilter(identifier, skip)
            }
        }
    }

    func parseEnumeratedTestIdentifiers(from data: Data) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: data)
        var identifiers: [String] = []
        var seen: Set<String> = []

        func append(_ value: String, requireQualifiedIdentifier: Bool = false) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else {
                return
            }
            if requireQualifiedIdentifier, !isQualifiedTestIdentifier(trimmed) {
                return
            }
            seen.insert(trimmed)
            identifiers.append(trimmed)
        }

        func canHoldQualifiedIdentifier(_ key: String) -> Bool {
            key == "name" || key == "tests" || key == "test" || key.contains("testname")
        }

        func walk(_ value: Any, stringRequiresQualifiedIdentifier: Bool? = nil) {
            if let string = value as? String {
                guard let requiresQualifiedIdentifier = stringRequiresQualifiedIdentifier else {
                    return
                }
                append(string, requireQualifiedIdentifier: requiresQualifiedIdentifier)
                return
            }
            if let array = value as? [Any] {
                for child in array {
                    walk(child, stringRequiresQualifiedIdentifier: stringRequiresQualifiedIdentifier)
                }
                return
            }
            guard let object = value as? [String: Any] else {
                return
            }
            for (key, child) in object {
                let normalizedKey = key.lowercased()
                if normalizedKey.contains("identifier") {
                    walk(child, stringRequiresQualifiedIdentifier: false)
                } else if canHoldQualifiedIdentifier(normalizedKey) {
                    walk(child, stringRequiresQualifiedIdentifier: true)
                } else {
                    walk(child)
                }
            }
        }

        walk(json)
        return identifiers
    }

    func splitTestIdentifiers(
        _ identifiers: [String],
        shardCount: Int,
        timingEstimates: [String: Double] = [:]
    ) -> [[String]] {
        guard shardCount > 1 else {
            return [identifiers]
        }
        guard !timingEstimates.isEmpty else {
            return splitTestIdentifiersRoundRobin(identifiers, shardCount: shardCount)
        }
        let knownDurations = identifiers.compactMap { timingEstimates[$0] }.filter { $0 > 0 }
        guard !knownDurations.isEmpty else {
            return splitTestIdentifiersRoundRobin(identifiers, shardCount: shardCount)
        }

        let defaultEstimate = knownDurations.reduce(0, +) / Double(knownDurations.count)
        let items = identifiers.enumerated()
            .map { offset, identifier in
                ManualShardPlannedTest(
                    index: offset,
                    identifier: identifier,
                    estimate: timingEstimates[identifier] ?? defaultEstimate
                )
            }
            .sorted {
                if $0.estimate == $1.estimate {
                    return $0.index < $1.index
                }
                return $0.estimate > $1.estimate
            }

        var groups = Array(repeating: [String](), count: shardCount)
        var totals = Array(repeating: 0.0, count: shardCount)
        for item in items {
            let destination = totals.enumerated().min {
                if $0.element == $1.element {
                    return $0.offset < $1.offset
                }
                return $0.element < $1.element
            }?.offset ?? 0
            groups[destination].append(item.identifier)
            totals[destination] += item.estimate
        }
        return groups.filter { !$0.isEmpty }
    }

    func aggregateResultClass(_ resultClasses: [ResultClass]) -> ResultClass {
        if resultClasses.contains(.canceled) {
            return .canceled
        }
        for resultClass in [ResultClass.buildTimeout, .buildFailure, .unsupportedDestination, .runnerBootstrapFailure, .artifactFailure, .testTimeout, .testFailure, .internalError] {
            if resultClasses.contains(resultClass) {
                return resultClass
            }
        }
        return .success
    }

    private func splitTestIdentifiersRoundRobin(_ identifiers: [String], shardCount: Int) -> [[String]] {
        var groups = Array(repeating: [String](), count: shardCount)
        for (index, identifier) in identifiers.enumerated() {
            groups[index % shardCount].append(identifier)
        }
        return groups.filter { !$0.isEmpty }
    }

    private func uniqueNonEmptyStrings(_ values: [String?]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty, !seen.contains(trimmed) else {
                continue
            }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private func isQualifiedTestIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
    }
}

private struct ManualShardPlannedTest {
    var index: Int
    var identifier: String
    var estimate: Double
}
