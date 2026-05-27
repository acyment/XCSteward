// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import Foundation

struct DoctorDiskHealth {
    let environment: AppEnvironment

    func freeDiskSpaceCheck() -> DoctorCheck {
        let path = environment.paths.stateRoot.path
        let failThreshold = diskThresholdBytes(
            environmentKey: "XCSTEWARD_DOCTOR_MIN_FREE_BYTES",
            defaultBytes: 2 * 1024 * 1024 * 1024
        )
        let warnThreshold = diskThresholdBytes(
            environmentKey: "XCSTEWARD_DOCTOR_WARN_FREE_BYTES",
            defaultBytes: 10 * 1024 * 1024 * 1024
        )

        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            guard let freeBytes = attributes[.systemFreeSize] as? NSNumber else {
                return DoctorCheck(
                    id: "global.free_disk_space",
                    status: .warn,
                    message: "Unable to read available disk space for \(path)",
                    autoFixable: false,
                    fixed: false,
                    manualAction: "Check free disk space manually before running simulator tests"
                )
            }

            let available = freeBytes.int64Value
            if available < failThreshold {
                return DoctorCheck(
                    id: "global.free_disk_space",
                    status: .fail,
                    message: "Only \(formatBytes(available)) free on the XCSteward state volume",
                    autoFixable: false,
                    fixed: false,
                    manualAction: "Free at least \(formatBytes(failThreshold)) before running SwiftPM or simulator jobs; inspect XCSteward-owned cleanup candidates with cleanup --dry-run using the same --state-root before deleting preserved evidence"
                )
            }
            if available < warnThreshold {
                return DoctorCheck(
                    id: "global.free_disk_space",
                    status: .warn,
                    message: "Only \(formatBytes(available)) free on the XCSteward state volume",
                    autoFixable: false,
                    fixed: false,
                    manualAction: "Free disk space before long simulator runs to avoid xcodebuild or SwiftPM I/O failures; inspect XCSteward-owned cleanup candidates with cleanup --dry-run using the same --state-root before deleting preserved evidence"
                )
            }

            return DoctorCheck(
                id: "global.free_disk_space",
                status: .pass,
                message: "\(formatBytes(available)) free on the XCSteward state volume",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        } catch {
            return DoctorCheck(
                id: "global.free_disk_space",
                status: .warn,
                message: "Unable to inspect disk space for \(path)",
                autoFixable: false,
                fixed: false,
                manualAction: "Check free disk space manually before running simulator tests"
            )
        }
    }

    func diskPressureWarningCheck() -> DoctorCheck {
        let path = environment.paths.stateRoot.path
        let warnPercent = diskThresholdPercent(
            environmentKey: "XCSTEWARD_DOCTOR_WARN_FREE_PERCENT",
            defaultPercent: 10
        )
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: path)
            guard let free = attributes[.systemFreeSize] as? NSNumber,
                  let total = attributes[.systemSize] as? NSNumber,
                  total.int64Value > 0 else {
                return DoctorCheck(
                    id: "global.disk_pressure_warning",
                    status: .warn,
                    message: "Unable to read disk pressure for the XCSteward state volume",
                    autoFixable: false,
                    fixed: false,
                    manualAction: "Check available disk capacity manually before running simulator jobs"
                )
            }

            let freePercent = (Double(free.int64Value) / Double(total.int64Value)) * 100
            if freePercent < Double(warnPercent) {
                return DoctorCheck(
                    id: "global.disk_pressure_warning",
                    status: .warn,
                    message: "Disk pressure is elevated on the XCSteward state volume (\(formatPercent(freePercent)) free)",
                    autoFixable: false,
                    fixed: false,
                    manualAction: "Free disk space before running parallel simulator jobs; CoreSimulator and result bundles are I/O intensive. Inspect XCSteward-owned cleanup candidates with cleanup --dry-run using the same --state-root before deleting preserved evidence"
                )
            }
            return DoctorCheck(
                id: "global.disk_pressure_warning",
                status: .pass,
                message: "Disk pressure is acceptable on the XCSteward state volume (\(formatPercent(freePercent)) free)",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        } catch {
            return DoctorCheck(
                id: "global.disk_pressure_warning",
                status: .warn,
                message: "Unable to inspect disk pressure for \(path)",
                autoFixable: false,
                fixed: false,
                manualAction: "Check available disk capacity manually before running simulator jobs"
            )
        }
    }

    private func diskThresholdBytes(environmentKey: String, defaultBytes: Int64) -> Int64 {
        guard let rawValue = environment.processInfo.environment[environmentKey],
              let parsed = Int64(rawValue),
              parsed >= 0
        else {
            return defaultBytes
        }
        return parsed
    }

    private func diskThresholdPercent(environmentKey: String, defaultPercent: Int) -> Int {
        guard let rawValue = environment.processInfo.environment[environmentKey],
              let parsed = Int(rawValue),
              parsed >= 0
        else {
            return defaultPercent
        }
        return parsed
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}
