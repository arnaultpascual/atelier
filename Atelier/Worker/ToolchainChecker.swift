// SPDX-License-Identifier: MIT
import Foundation
import Subprocess
import System

/// Probes whether a mode's build/test toolchain is actually installed, so Atelier can tell
/// "tooling missing" apart from "tests red". Without this, a missing Android SDK / JDK makes
/// `./gradlew test` exit non-zero and the gate would mislabel it a test failure and fix-loop.
enum ToolchainChecker {
    struct ToolStatus: Sendable, Identifiable {
        let id: String
        let label: String
        let present: Bool
        let detail: String        // where it was found, or what's missing
        let installHint: String
        let required: Bool
    }

    struct Report: Sendable {
        let tools: [ToolStatus]
        var requiredMissing: [ToolStatus] { tools.filter { $0.required && !$0.present } }
        var ready: Bool { requiredMissing.isEmpty }
        /// "Android SDK, Gradle wrapper" — for one-line messages.
        var missingSummary: String { requiredMissing.map(\.label).joined(separator: ", ") }
    }

    /// Checks every declared tool for the mode against the project. `projectPath` is the main repo
    /// root (has the committed `gradlew` and any `local.properties`).
    /// `projectPath` is the worktree (executable + gradlew live there); `mainRepoPath` is the main
    /// repo, used ONLY for `local.properties` (gitignored, so it's never materialized in a worktree).
    /// Defaults `mainRepoPath` to `projectPath` for main-repo callers (preflight / settings).
    static func check(profile: ProjectProfile, projectPath: String, mainRepoPath: String? = nil) async -> Report {
        let mainRepo = mainRepoPath ?? projectPath
        var statuses: [ToolStatus] = []
        for tool in profile.build.requiredTools {
            let (present, detail) = await probe(tool.probe, projectPath: projectPath, mainRepoPath: mainRepo)
            statuses.append(ToolStatus(id: tool.id, label: tool.label, present: present,
                                       detail: detail, installHint: tool.installHint, required: tool.required))
        }
        return Report(tools: statuses)
    }

    /// Environment vars Atelier injects into the test/build subprocess so a "ready" verdict actually
    /// holds — e.g. exporting ANDROID_HOME, since a Finder-launched GUI app doesn't inherit the
    /// shell's exports and the Android Gradle Plugin won't auto-detect ~/Library/Android/sdk.
    static func environmentExports(profile: ProjectProfile, mainRepoPath: String) -> [String: String] {
        var out: [String: String] = [:]
        let needsAndroid = profile.build.requiredTools.contains {
            if case .androidSdk = $0.probe { return true }; return false
        }
        if needsAndroid, let sdk = resolvedAndroidSdkPath(mainRepoPath: mainRepoPath) {
            out["ANDROID_HOME"] = sdk
            out["ANDROID_SDK_ROOT"] = sdk
        }
        return out
    }

    // MARK: - Probes

    private static func probe(_ probe: ProjectProfile.ToolRequirement.Probe,
                             projectPath: String, mainRepoPath: String) async -> (Bool, String) {
        switch probe {
        case .executable(let name):
            if let path = await resolveExecutable(name, projectPath: projectPath) {
                return (true, path)
            }
            return (false, "`\(name)` not found on PATH")
        case .fileInProject(let rel):
            let p = URL(fileURLWithPath: projectPath).appendingPathComponent(rel).path
            return FileManager.default.fileExists(atPath: p) ? (true, rel) : (false, "missing \(rel)")
        case .androidSdk:
            if let sdk = resolvedAndroidSdkPath(mainRepoPath: mainRepoPath) {
                return (true, sdk)
            }
            return (false, "no ANDROID_HOME, ~/Library/Android/sdk, or local.properties sdk.dir")
        }
    }

    /// Matches how the test subprocess resolves a command: well-known dirs first, then `command -v`
    /// under the inherited environment (TestRunner runs `/bin/sh -c` with `.inherit`).
    private static func resolveExecutable(_ name: String, projectPath: String) async -> String? {
        let fm = FileManager.default
        for dir in ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin"] {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        // Fall back to `command -v` in the same shell context the gate uses.
        let collector = LineSink()
        do {
            let outcome = try await Subprocess.run(
                .path(FilePath("/bin/sh")),
                arguments: Arguments(["-c", "command -v \(name)"]),
                environment: .inherit,
                workingDirectory: FilePath(projectPath),
                body: { execution, inputWriter, stdout, stderr in
                    try await inputWriter.finish()
                    for try await line in stdout.lines() { await collector.append(line) }
                    for try await _ in stderr.lines() {}
                    _ = execution
                }
            )
            let ok: Bool
            switch outcome.terminationStatus {
            case .exited(let code): ok = (code == 0)
            case .signaled: ok = false
            }
            let path = await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return (ok && !path.isEmpty) ? path : nil
        } catch {
            return nil
        }
    }

    /// Resolves the Android SDK path Atelier will export to the build (so the checker's verdict and
    /// the actual gradle run agree). Search order: ANDROID_HOME / ANDROID_SDK_ROOT (if the dir
    /// exists) → ~/Library/Android/sdk → `local.properties` `sdk.dir` in the MAIN repo. nil = none.
    static func resolvedAndroidSdkPath(mainRepoPath: String) -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let dir = env[key], !dir.isEmpty, fm.fileExists(atPath: dir) { return dir }
        }
        let defaultSdk = NSHomeDirectory() + "/Library/Android/sdk"
        if fm.fileExists(atPath: defaultSdk) { return defaultSdk }
        let lp = URL(fileURLWithPath: mainRepoPath).appendingPathComponent("local.properties")
        if let contents = try? String(contentsOf: lp, encoding: .utf8),
           let line = contents.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("sdk.dir") }),
           let eq = line.firstIndex(of: "=") {
            let dir = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !dir.isEmpty { return dir }
        }
        return nil
    }
}

private actor LineSink {
    private(set) var value: String = ""
    func append(_ line: String) { value += line + "\n" }
}
