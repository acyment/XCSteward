import Foundation

private struct ProtectedProfilePath {
    var label: String
    var url: URL
}

struct DoctorPathSafety {
    let environment: AppEnvironment

    func protectedPathWarningCheck() -> DoctorCheck {
        let path = normalizeDoctorPath(environment.paths.stateRoot.path)
        if let matched = protectedPathPrefix(for: path) {
            return DoctorCheck(
                id: "global.protected_path_warning",
                status: .warn,
                message: "XCSteward state root is under a protected or high-risk path: \(matched)",
                autoFixable: false,
                fixed: false,
                manualAction: "Move XCSTEWARD_HOME or --state-root to an unprotected developer-owned path such as ~/.xcsteward"
            )
        }
        return DoctorCheck(
            id: "global.protected_path_warning",
            status: .pass,
            message: "XCSteward state root is not under a known protected path",
            autoFixable: false,
            fixed: false,
            manualAction: nil
        )
    }

    func projectProtectedPathWarningCheck(profile: ProjectProfile) -> DoctorCheck {
        let matches = protectedProfilePaths(profile: profile).compactMap { entry -> String? in
            let normalized = normalizeDoctorPath(entry.url.path)
            guard let matched = protectedPathPrefix(for: normalized) else {
                return nil
            }
            return "\(entry.label): \(normalized) under \(matched)"
        }
        guard !matches.isEmpty else {
            return DoctorCheck(
                id: "project.protected_path_warning",
                status: .pass,
                message: "Project profile paths are not under known protected paths",
                autoFixable: false,
                fixed: false,
                manualAction: nil
            )
        }
        return DoctorCheck(
            id: "project.protected_path_warning",
            status: .warn,
            message: "Project profile paths are under protected or high-risk paths: \(matches.joined(separator: "; "))",
            autoFixable: false,
            fixed: false,
            manualAction: "Move repo roots, project/workspace paths, and explicit build output overrides to developer-owned paths"
        )
    }

    private func protectedPathPrefix(for path: String) -> String? {
        protectedPathPrefixes().first { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private func protectedProfilePaths(profile: ProjectProfile) -> [ProtectedProfilePath] {
        let repoURL = URL(fileURLWithPath: profile.repoRoot).standardizedFileURL
        var paths = [
            ProtectedProfilePath(label: "repo_root", url: repoURL),
        ]
        if let projectPath = profile.projectPath, !projectPath.isEmpty {
            paths.append(
                ProtectedProfilePath(
                    label: "project_path",
                    url: profilePathURL(projectPath, relativeTo: repoURL)
                )
            )
        }
        if let workspacePath = profile.workspacePath, !workspacePath.isEmpty {
            paths.append(
                ProtectedProfilePath(
                    label: "workspace_path",
                    url: profilePathURL(workspacePath, relativeTo: repoURL)
                )
            )
        }
        for key in ["DERIVED_DATA_PATH", "SYMROOT", "OBJROOT"] {
            guard let rawPath = profile.env[key], !rawPath.isEmpty else {
                continue
            }
            paths.append(
                ProtectedProfilePath(
                    label: key,
                    url: profilePathURL(rawPath, relativeTo: repoURL)
                )
            )
        }
        return paths
    }

    private func profilePathURL(_ path: String, relativeTo baseURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return baseURL.appendingPathComponent(path).standardizedFileURL
    }

    private func protectedPathPrefixes() -> [String] {
        var prefixes = [
            "/Applications",
            "/Library",
            "/System",
            "/bin",
            "/sbin",
            "/usr",
            "/private/var/root",
            "/var/root",
        ]
        if let home = environment.processInfo.environment["HOME"] {
            let normalizedHome = normalizeDoctorPath(home)
            prefixes += [
                "\(normalizedHome)/Desktop",
                "\(normalizedHome)/Documents",
                "\(normalizedHome)/Downloads",
                "\(normalizedHome)/Library/Mobile Documents",
            ]
        }
        if let extra = environment.processInfo.environment["XCSTEWARD_DOCTOR_PROTECTED_PATHS"] {
            prefixes += extra
                .split(separator: ":")
                .map(String.init)
                .map(normalizeDoctorPath)
        }
        return prefixes.map(normalizeDoctorPath)
    }
}

func normalizeDoctorPath(_ output: String) -> String {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(fileURLWithPath: trimmed).standardizedFileURL.path
}
