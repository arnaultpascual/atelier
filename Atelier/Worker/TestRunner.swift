// SPDX-License-Identifier: MIT
import Foundation
import Subprocess
import System
import os

/// Runs a mode's test command(s) inside a worktree and gates on the exit code.
///
/// The worker's self-report ("tests pass") is never the authority — a real, non-zero
/// process exit is, exactly as ReviewSection/autopilot treat git state (not the model's
/// stdout) as truth. Mirrors `GitService`'s shell-out pattern, plus a wall-clock timeout
/// so a hung Gradle daemon can't wedge the run.
enum TestRunner {
    private static let logger = Logger(subsystem: "app.atelier", category: "tests")

    struct CommandOutcome: Sendable {
        let id: String
        let command: String
        let exitCode: Int32
        let timedOut: Bool
        let stdoutTail: String
        let stderrTail: String
        let duration: TimeInterval
        var passed: Bool { exitCode == 0 && !timedOut }
    }

    struct Result: Sendable {
        let passed: Bool          // every fast command exited 0
        let ranAnything: Bool     // false when the mode has no fast test command
        let perCommand: [CommandOutcome]
        let summaryLine: String   // best-effort one-liner (cosmetic; exit code is the gate)
        var toolchainMissing: Bool = false   // tools to run tests aren't installed — NOT a test failure
        var missingTools: [String] = []
    }

    /// Runs the mode's `.fast` test commands in `worktreePath`, in order, short-circuiting
    /// on the first failure. `ranAnything == false` when the mode has no fast test command —
    /// the caller maps that to `.noTests` (gate is informational).
    /// Runs the mode's `.fast` test commands. `retriesOnRed` re-runs the whole fast set once more
    /// when it fails (anti-flaky): a suite that passes on retry was flaky, not broken — this stops
    /// the fix loop from "fixing" flakiness by deleting the unstable test. Genuine failures still
    /// fail (they fail every attempt); the cost is one extra run only on red.
    static func runFastTests(profile: ProjectProfile,
                             worktreePath: String,
                             mainRepoPath: String? = nil,
                             timeoutSeconds: Double = 900,
                             retriesOnRed: Int = 1) async -> Result {
        let cmds = profile.build.fastTestCommands
        guard !cmds.isEmpty else {
            return Result(passed: true, ranAnything: false, perCommand: [],
                          summaryLine: "No test command configured for this mode.")
        }
        guard FileManager.default.fileExists(atPath: worktreePath) else {
            return Result(passed: false, ranAnything: false, perCommand: [],
                          summaryLine: "Worktree not found — cannot run tests.")
        }
        let mainRepo = mainRepoPath ?? worktreePath
        // Toolchain preflight: a missing JDK/SDK/wrapper must NOT be read as a test failure.
        // local.properties resolves against the MAIN repo (it's gitignored, absent in worktrees).
        let toolReport = await ToolchainChecker.check(profile: profile, projectPath: worktreePath, mainRepoPath: mainRepo)
        if !toolReport.ready {
            return Result(passed: false, ranAnything: false, perCommand: [],
                          summaryLine: "Toolchain not ready: \(toolReport.missingSummary)",
                          toolchainMissing: true, missingTools: toolReport.requiredMissing.map(\.label))
        }
        // Inject resolved toolchain env (e.g. ANDROID_HOME) so the build actually finds the SDK —
        // a GUI app doesn't inherit the shell's exports.
        let prefix = envPrefix(ToolchainChecker.environmentExports(profile: profile, mainRepoPath: mainRepo))
        var result = await runOnce(cmds, worktreePath: worktreePath, envPrefix: prefix, timeoutSeconds: timeoutSeconds)
        var left = retriesOnRed
        while !result.passed && left > 0 {
            left -= 1
            let retry = await runOnce(cmds, worktreePath: worktreePath, envPrefix: prefix, timeoutSeconds: timeoutSeconds)
            if retry.passed {
                return Result(passed: true, ranAnything: true, perCommand: retry.perCommand,
                              summaryLine: "Passed on retry (first run was flaky): \(retry.summaryLine)")
            }
            result = retry
        }
        return result
    }

    private static func runOnce(_ cmds: [ProjectProfile.TestCommand],
                                worktreePath: String,
                                envPrefix: String,
                                timeoutSeconds: Double) async -> Result {
        var outcomes: [CommandOutcome] = []
        for cmd in cmds {
            let outcome = await runOne(id: cmd.id, command: cmd.command, worktreePath: worktreePath,
                                       envPrefix: envPrefix, timeoutSeconds: timeoutSeconds)
            outcomes.append(outcome)
            if !outcome.passed { break }   // first failure gates the whole run
        }
        let passed = outcomes.allSatisfy { $0.passed }
        return Result(passed: passed, ranAnything: true, perCommand: outcomes,
                      summaryLine: summarize(outcomes))
    }

    /// Runs an arbitrary command in the worktree (used by opt-in build verification, which may use a
    /// custom/fast target). Returns nil if the worktree is missing. Builds can be slow → 30-min cap.
    /// Injects the mode's resolved toolchain env (e.g. ANDROID_HOME) like the test gate.
    static func runCommand(_ command: String,
                           worktreePath: String,
                           profile: ProjectProfile,
                           mainRepoPath: String,
                           timeoutSeconds: Double = 1800) async -> CommandOutcome? {
        guard FileManager.default.fileExists(atPath: worktreePath) else { return nil }
        let prefix = envPrefix(ToolchainChecker.environmentExports(profile: profile, mainRepoPath: mainRepoPath))
        return await runOne(id: "verify-build", command: command, worktreePath: worktreePath,
                            envPrefix: prefix, timeoutSeconds: timeoutSeconds)
    }

    /// Builds a `KEY='value' KEY2='value2' ` shell prefix from env exports (sorted for determinism).
    private static func envPrefix(_ exports: [String: String]) -> String {
        guard !exports.isEmpty else { return "" }
        return exports.keys.sorted()
            .map { "\($0)='\(exports[$0]!.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ") + " "
    }

    // MARK: - Internals

    private enum Race: Sendable { case finished(Int32); case timedOut }

    private static func runOne(id: String,
                               command: String,
                               worktreePath: String,
                               envPrefix: String = "",
                               timeoutSeconds: Double) async -> CommandOutcome {
        let collector = TestOutputCollector()
        let started = Date()
        let fullCommand = envPrefix + command
        let race: Race = await withTaskGroup(of: Race.self) { group in
            group.addTask {
                let code = await runShell(command: fullCommand, worktreePath: worktreePath, collector: collector)
                return .finished(code)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutSeconds) * 1_000_000_000))
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()   // cancel the loser; cancellation terminates the subprocess
            return first
        }
        let duration = Date().timeIntervalSince(started)
        let stdoutTail = await collector.tailStdout()
        let stderrTail = await collector.tailStderr()
        switch race {
        case .timedOut:
            logger.warning("test command timed out: \(command, privacy: .public)")
            return CommandOutcome(id: id, command: command, exitCode: -1, timedOut: true,
                                  stdoutTail: stdoutTail, stderrTail: stderrTail, duration: duration)
        case .finished(let code):
            return CommandOutcome(id: id, command: command, exitCode: code, timedOut: false,
                                  stdoutTail: stdoutTail, stderrTail: stderrTail, duration: duration)
        }
    }

    private static func runShell(command: String,
                                 worktreePath: String,
                                 collector: TestOutputCollector) async -> Int32 {
        do {
            let outcome = try await Subprocess.run(
                .path(FilePath("/bin/sh")),
                arguments: Arguments(["-c", command]),
                environment: .inherit,
                workingDirectory: FilePath(worktreePath),
                body: { execution, inputWriter, stdout, stderr in
                    try await inputWriter.finish()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await line in stdout.lines() { await collector.appendStdout(line) }
                        }
                        group.addTask {
                            for try await line in stderr.lines() { await collector.appendStderr(line) }
                        }
                        try await group.waitForAll()
                    }
                    _ = execution
                }
            )
            switch outcome.terminationStatus {
            case .exited(let code): return code
            case .signaled: return 137   // non-zero → counts as a failure
            }
        } catch {
            return Task.isCancelled ? -1 : -2
        }
    }

    /// Best-effort one-liner pulled from the output. Exit code is the gate; this is cosmetic.
    private static func summarize(_ outcomes: [CommandOutcome]) -> String {
        if let failed = outcomes.first(where: { !$0.passed }) {
            if failed.timedOut { return "Timed out after \(Int(failed.duration))s: \(failed.command)" }
            let combined = failed.stdoutTail + "\n" + failed.stderrTail
            if let line = lastLine(in: combined, containing: ["fail", "error:", "exception"]) {
                return String(line.prefix(160))
            }
            return "Tests failed (exit \(failed.exitCode)): \(failed.command)"
        }
        let combined = outcomes.map(\.stdoutTail).joined(separator: "\n")
        if let line = lastLine(in: combined, containing: ["passed", "completed", "build successful"]) {
            return String(line.prefix(160))
        }
        return "Tests passed."
    }

    private static func lastLine(in text: String, containing needles: [String]) -> String? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines.reversed() where !line.isEmpty {
            let low = line.lowercased()
            if needles.contains(where: { low.contains($0) }) { return line }
        }
        return nil
    }
}

private actor TestOutputCollector {
    private var stdout: String = ""
    private var stderr: String = ""
    private let cap = 16_000   // keep memory bounded for chatty suites

    func appendStdout(_ line: String) { append(&stdout, line) }
    func appendStderr(_ line: String) { append(&stderr, line) }

    private func append(_ buf: inout String, _ line: String) {
        guard !line.isEmpty else { return }
        buf += line + "\n"
        if buf.count > cap { buf = String(buf.suffix(cap)) }
    }

    func tailStdout() -> String { String(stdout.suffix(4000)) }
    func tailStderr() -> String { String(stderr.suffix(4000)) }
}
