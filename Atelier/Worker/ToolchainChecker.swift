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
        let needsDotnet = profile.build.requiredTools.contains {
            if case .dotnetSdk = $0.probe { return true }; return false
        }
        if needsDotnet, let bin = resolvedDotnetBinary() {
            if let root = resolvedDotnetRoot() { out["DOTNET_ROOT"] = root }
            // The gate runs bare `dotnet test`, but a Finder-launched GUI app doesn't inherit the
            // shell PATH, so `dotnet` wouldn't resolve. We can't hand back a `$PATH`-relative value:
            // TestRunner.envPrefix single-quotes export values (so `$PATH` wouldn't expand), and the
            // worker consumes the same map as a raw env dict (no shell at all). So resolve PATH
            // CONCRETELY here — prepend dotnet's dir to the inherited PATH — which is correct for both
            // the single-quoted test prefix and the worker's env dict.
            let dir = URL(fileURLWithPath: bin).deletingLastPathComponent().path
            let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            out["PATH"] = dir + ":" + base
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
        case .dotnetSdk:
            return await probeDotnetSdk()
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

    // MARK: - .NET SDK resolution

    /// Resolves a runnable `dotnet` host. A GUI app doesn't inherit the shell PATH, so we probe the
    /// well-known install locations directly (matching how the gate finds it once we prepend its dir
    /// to PATH). Search: DOTNET_ROOT → ~/.dotnet → /usr/local/share/dotnet → Homebrew → system bins.
    static func resolvedDotnetBinary() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let root = env["DOTNET_ROOT"], !root.isEmpty { candidates.append(root + "/dotnet") }
        candidates.append(NSHomeDirectory() + "/.dotnet/dotnet")
        candidates.append("/usr/local/share/dotnet/dotnet")
        candidates.append("/opt/homebrew/share/dotnet/dotnet")
        candidates.append("/usr/local/bin/dotnet")
        candidates.append("/opt/homebrew/bin/dotnet")
        candidates.append("/usr/bin/dotnet")
        for p in candidates where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// `DOTNET_ROOT` we export so the host finds `sdk/` and `shared/`. Prefer an explicit env value;
    /// else derive the install root from the resolved binary. We VALIDATE the candidate actually holds
    /// an `sdk/` dir and walk up a few levels for bin/-shim layouts (e.g. Homebrew's
    /// …/Cellar/dotnet/X/bin/dotnet, where the binary is NOT directly at the root). If we can't find a
    /// real root, return nil and export nothing — the host self-locates from the binary on PATH, and a
    /// bogus DOTNET_ROOT (missing sdk/) would actively BREAK resolution, worse than leaving it unset.
    static func resolvedDotnetRoot() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let root = env["DOTNET_ROOT"], !root.isEmpty, isDotnetRoot(root) { return root }
        guard let bin = resolvedDotnetBinary() else { return nil }
        var dir = URL(fileURLWithPath: bin).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<3 {
            if isDotnetRoot(dir.path) { return dir.path }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// A .NET install root is a directory containing an `sdk` subdirectory (next to `shared/`, `host/`).
    private static func isDotnetRoot(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let sdk = URL(fileURLWithPath: path).appendingPathComponent("sdk").path
        return FileManager.default.fileExists(atPath: sdk, isDirectory: &isDir) && isDir.boolValue
    }

    /// Probe for `.dotnetSdk`: a `dotnet` host exists AND at least one SDK with major ≥ 8 (8.x or
    /// 10.x) is installed. Surfaces the preferred (highest, so 10 over 8) version in `detail`.
    private static func probeDotnetSdk() async -> (Bool, String) {
        guard let bin = resolvedDotnetBinary() else {
            return (false, "no `dotnet` host (checked DOTNET_ROOT, ~/.dotnet, /usr/local/share/dotnet, Homebrew, system bins)")
        }
        let sdks = await listDotnetSdks(binary: bin)        // e.g. ["8.0.404 [..]", "10.0.100 [..]"]
        let majors = sdks.compactMap(dotnetSdkMajor)
        guard let chosen = majors.filter({ $0 >= 8 }).max() else {   // highest major: prefer 10 over 8
            if sdks.isEmpty {
                return (false, "`dotnet` at \(bin) but no SDK installed — install .NET 8 or 10 (`dotnet --list-sdks`)")
            }
            let found = Set(majors).sorted().map(String.init).joined(separator: ", ")
            return (false, "`dotnet` SDK major(s) \(found) found, need ≥ 8 — install .NET 8 or 10")
        }
        let line = sdks.first(where: { dotnetSdkMajor($0) == chosen }) ?? ""
        let version = line.split(separator: " ").first.map(String.init) ?? "\(chosen).x"
        return (true, "SDK \(version) (\(bin))")
    }

    /// Parses the major version from a `dotnet --list-sdks` line ("8.0.404 [/path/sdk]" → 8).
    private static func dotnetSdkMajor(_ line: String) -> Int? {
        let version = line.split(separator: " ").first.map(String.init) ?? line
        return version.split(separator: ".").first.flatMap { Int($0) }
    }

    /// Runs `<dotnet> --list-sdks` and returns its non-empty lines. Best-effort (errors → []). Runs
    /// the resolved binary directly with `.inherit`, like `resolveExecutable`'s `command -v` probe;
    /// the host self-locates its SDKs from its own path.
    private static func listDotnetSdks(binary: String) async -> [String] {
        let collector = LineSink()
        do {
            _ = try await Subprocess.run(
                .path(FilePath(binary)),
                arguments: Arguments(["--list-sdks"]),
                environment: .inherit,
                workingDirectory: FilePath(NSHomeDirectory()),
                body: { execution, inputWriter, stdout, stderr in
                    try await inputWriter.finish()
                    for try await line in stdout.lines() { await collector.append(line) }
                    for try await _ in stderr.lines() {}
                    _ = execution
                }
            )
        } catch {
            return []
        }
        let text = await collector.value
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

private actor LineSink {
    private(set) var value: String = ""
    func append(_ line: String) { value += line + "\n" }
}
