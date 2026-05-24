// SPDX-License-Identifier: MIT
import Foundation
import Subprocess
import System
import os

/// Thin wrapper around the user's `git` binary for the worktree and diff-stat
/// operations we need at spawn time. Phase 1 uses shell-out (per spec §11.1);
/// libgit2 / SwiftGit2 stays out of scope until performance becomes a concern.
enum GitService {
    private static let logger = Logger(subsystem: "app.atelier", category: "git")

    struct WorktreeInfo: Sendable {
        let absolutePath: String         // e.g. `<repo>/.atelier-worktrees/task-001`
        let relativePath: String         // e.g. `.atelier-worktrees/task-001`
        let branch: String               // e.g. `worktree-task-001`
        let reused: Bool                 // true if the worktree already existed
    }

    struct DiffStat: Sendable, Equatable {
        let filesChanged: Int
        let insertions: Int
        let deletions: Int
        var isEmpty: Bool { filesChanged == 0 && insertions == 0 && deletions == 0 }
    }

    /// Outcome of merging a worktree branch into the base branch.
    enum MergeResult: Sendable, Equatable {
        case clean(sha: String)          // merged with a new --no-ff commit
        case upToDate                    // base already contained the branch
        case conflict(files: [String])   // merge left unmerged paths (MERGE_HEAD in progress)
    }

    enum Error: Swift.Error, LocalizedError {
        case gitNotFound
        case notARepo(String)
        case worktreeCreateFailed(String)
        case worktreeRemoveFailed(String)
        case commandFailed(String, stderr: String)

        var errorDescription: String? {
            switch self {
            case .gitNotFound:
                return "Could not find the `git` executable."
            case .notARepo(let p):
                return "\(p) is not a git repository. Run `git init` there first."
            case .worktreeCreateFailed(let msg):
                return "git worktree add failed: \(msg)"
            case .worktreeRemoveFailed(let msg):
                return "git worktree remove failed: \(msg)"
            case .commandFailed(let cmd, let err):
                return "`\(cmd)` failed: \(err.prefix(300))"
            }
        }
    }

    // MARK: - Public API

    /// Public probe for the user's `git` binary (same well-known locations as the
    /// internal runner). Returns nil if none has an executable `git`.
    static func locate() -> String? {
        resolveGit()
    }

    /// Ensures a git worktree exists for the given task. Idempotent — if the path
    /// already exists and is a worktree, returns info with `reused = true`.
    static func ensureWorktree(projectPath: String, taskId: String) async throws -> WorktreeInfo {
        let fm = FileManager.default
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        guard fm.fileExists(atPath: projectURL.appendingPathComponent(".git").path) else {
            throw Error.notARepo(projectPath)
        }

        let relative = ".atelier-worktrees/\(taskId)"
        let absolute = projectURL.appendingPathComponent(relative).path
        let branch = "worktree-\(taskId)"

        if fm.fileExists(atPath: absolute) {
            return WorktreeInfo(absolutePath: absolute,
                                relativePath: relative,
                                branch: branch,
                                reused: true)
        }

        // Make sure the parent dir exists (.atelier-worktrees/ is gitignored already).
        try fm.createDirectory(at: projectURL.appendingPathComponent(".atelier-worktrees"),
                               withIntermediateDirectories: true)

        // If the branch already exists from a previous run, re-attach instead of -b.
        let branchExists = try await branchExists(projectPath: projectPath, branch: branch)
        var args: [String] = ["worktree", "add"]
        if branchExists {
            args += [relative, branch]
        } else {
            args += [relative, "-b", branch]
        }

        let result = try await runGit(args: args, workingDirectory: projectPath)
        if !result.success {
            throw Error.worktreeCreateFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return WorktreeInfo(absolutePath: absolute,
                            relativePath: relative,
                            branch: branch,
                            reused: false)
    }

    /// Removes a worktree. `force` keeps going even if the worktree has uncommitted
    /// changes — caller decides whether to ask the user first.
    static func removeWorktree(projectPath: String, taskId: String, force: Bool = false) async throws {
        let relative = ".atelier-worktrees/\(taskId)"
        var args: [String] = ["worktree", "remove", relative]
        if force { args.append("--force") }
        let result = try await runGit(args: args, workingDirectory: projectPath)
        if !result.success {
            throw Error.worktreeRemoveFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    /// `git diff --shortstat` of the worktree branch vs the project's current HEAD.
    static func diffStat(projectPath: String, branch: String) async throws -> DiffStat {
        // Find the merge base with HEAD so we report the worktree's "own" changes.
        let baseResult = try await runGit(args: ["merge-base", "HEAD", branch],
                                          workingDirectory: projectPath)
        let base = baseResult.success
            ? baseResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : "HEAD"

        let statResult = try await runGit(
            args: ["diff", "--shortstat", "\(base)..\(branch)"],
            workingDirectory: projectPath
        )
        guard statResult.success else {
            throw Error.commandFailed("git diff --shortstat", stderr: statResult.stderr)
        }
        return parseShortStat(statResult.stdout)
    }

    struct ChangedFile: Sendable, Hashable, Identifiable {
        let path: String
        let status: ChangeStatus
        var id: String { path }
    }

    enum ChangeStatus: Sendable, Hashable {
        case added, modified, deleted, renamed, untracked, other(String)

        var label: String {
            switch self {
            case .added: return "added"
            case .modified: return "modified"
            case .deleted: return "deleted"
            case .renamed: return "renamed"
            case .untracked: return "new"
            case .other(let s): return s
            }
        }

        var symbol: String {
            switch self {
            case .added, .untracked: return "+"
            case .modified: return "M"
            case .deleted: return "−"
            case .renamed: return "R"
            case .other: return "?"
            }
        }
    }

    /// Lists files changed on `branch` vs. the merge-base with HEAD. Also picks up
    /// untracked / uncommitted changes that live inside the worktree on disk.
    static func changedFiles(projectPath: String, branch: String, taskId: String) async throws -> [ChangedFile] {
        let baseResult = try await runGit(args: ["merge-base", "HEAD", branch],
                                          workingDirectory: projectPath)
        let base = baseResult.success
            ? baseResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : "HEAD"

        // Committed changes between base and the branch tip.
        let diffResult = try await runGit(
            args: ["diff", "--name-status", "\(base)..\(branch)"],
            workingDirectory: projectPath
        )
        guard diffResult.success else {
            throw Error.commandFailed("git diff --name-status", stderr: diffResult.stderr)
        }

        var files: [ChangedFile] = []
        var seenPaths: Set<String> = []
        for line in diffResult.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let code = String(parts[0])
            let path = String(parts[parts.count - 1])
            let status: ChangeStatus = {
                switch code.first {
                case "A": return .added
                case "M": return .modified
                case "D": return .deleted
                case "R": return .renamed
                default:  return .other(code)
                }
            }()
            files.append(ChangedFile(path: path, status: status))
            seenPaths.insert(path)
        }

        // Pick up uncommitted / untracked stuff that's sitting in the worktree on disk
        // but the worker forgot to commit. Run `git status --porcelain` *inside* the
        // worktree directory.
        let worktreeDir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".atelier-worktrees")
            .appendingPathComponent(taskId)
            .path
        if FileManager.default.fileExists(atPath: worktreeDir) {
            let statusResult = try? await runGit(
                args: ["status", "--porcelain"],
                workingDirectory: worktreeDir
            )
            if let statusResult, statusResult.success {
                for line in statusResult.stdout.split(separator: "\n") {
                    let raw = String(line)
                    guard raw.count >= 4 else { continue }
                    let code = String(raw.prefix(2))
                    let path = String(raw.dropFirst(3))
                    if seenPaths.contains(path) { continue }
                    let status: ChangeStatus = {
                        if code.contains("?") { return .untracked }
                        if code.contains("D") { return .deleted }
                        if code.contains("A") { return .added }
                        if code.contains("M") { return .modified }
                        return .other(code.trimmingCharacters(in: .whitespaces))
                    }()
                    files.append(ChangedFile(path: path, status: status))
                    seenPaths.insert(path)
                }
            }
        }

        return files
    }

    /// Reads the file content from the worktree on disk.
    static func readWorktreeFile(projectPath: String, taskId: String, relativePath: String) -> Data? {
        let url = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".atelier-worktrees")
            .appendingPathComponent(taskId)
            .appendingPathComponent(relativePath)
        return try? Data(contentsOf: url)
    }

    static func branchExists(projectPath: String, branch: String) async throws -> Bool {
        let result = try await runGit(
            args: ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
            workingDirectory: projectPath
        )
        return result.success
    }

    // MARK: - Merge (autopilot)

    /// The currently checked-out branch in the main repo, or "HEAD" when detached.
    static func currentBranch(projectPath: String) async throws -> String {
        let r = try await runGit(args: ["rev-parse", "--abbrev-ref", "HEAD"], workingDirectory: projectPath)
        guard r.success else { throw Error.commandFailed("git rev-parse --abbrev-ref HEAD", stderr: r.stderr) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the given repo's working tree has no uncommitted changes.
    static func isClean(projectPath: String) async throws -> Bool {
        let r = try await runGit(args: ["status", "--porcelain"], workingDirectory: projectPath)
        guard r.success else { throw Error.commandFailed("git status --porcelain", stderr: r.stderr) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Files with unmerged paths (conflict markers). Empty when there's no conflict.
    static func unmergedFiles(projectPath: String) async throws -> [String] {
        let r = try await runGit(args: ["diff", "--name-only", "--diff-filter=U"], workingDirectory: projectPath)
        return r.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// True while a merge is in progress (MERGE_HEAD present) — e.g. mid-conflict.
    static func isMergeInProgress(projectPath: String) async throws -> Bool {
        let r = try await runGit(args: ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], workingDirectory: projectPath)
        return r.success
    }

    /// Commits everything in a task's worktree (`git add -A && git commit`). Returns false
    /// (no-op) when the worktree is already clean. Workers are told to commit their own work;
    /// this catches anything they left staged/uncommitted before we merge.
    @discardableResult
    static func commitWorktree(projectPath: String, taskId: String, message: String) async throws -> Bool {
        let worktreeDir = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".atelier-worktrees")
            .appendingPathComponent(taskId).path
        let status = try await runGit(args: ["status", "--porcelain"], workingDirectory: worktreeDir)
        guard status.success else { throw Error.commandFailed("git status --porcelain", stderr: status.stderr) }
        if status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        let add = try await runGit(args: ["add", "-A"], workingDirectory: worktreeDir)
        guard add.success else { throw Error.commandFailed("git add -A", stderr: add.stderr) }
        let commit = try await runGit(args: ["commit", "-m", message], workingDirectory: worktreeDir)
        guard commit.success else { throw Error.commandFailed("git commit", stderr: commit.stderr) }
        return true
    }

    /// Merges `branch` into `base` in the main repo with a `--no-ff` commit (always an explicit,
    /// revertable merge commit). The caller MUST have `base` checked out. Returns `.clean` /
    /// `.upToDate`, or `.conflict(files:)` leaving the merge in progress for a resolver to finish.
    /// Never pushes.
    static func merge(into base: String, branch: String, projectPath: String) async throws -> MergeResult {
        let result = try await runGit(args: ["merge", "--no-ff", "--no-edit", branch],
                                      workingDirectory: projectPath)
        if result.success {
            if result.stdout.localizedCaseInsensitiveContains("up to date") {
                return .upToDate
            }
            let head = try await runGit(args: ["rev-parse", "HEAD"], workingDirectory: projectPath)
            return .clean(sha: head.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let files = try await unmergedFiles(projectPath: projectPath)
        if !files.isEmpty { return .conflict(files: files) }
        // Non-conflict failure (dirty tree, unrelated histories, …) — surface it.
        throw Error.commandFailed("git merge --no-ff \(branch)",
                                  stderr: result.stderr.isEmpty ? result.stdout : result.stderr)
    }

    /// Aborts an in-progress merge, restoring the base branch to pre-merge state.
    static func abortMerge(projectPath: String) async throws {
        let r = try await runGit(args: ["merge", "--abort"], workingDirectory: projectPath)
        guard r.success else { throw Error.commandFailed("git merge --abort", stderr: r.stderr) }
    }

    /// Creates and checks out a new branch off the current HEAD — the autopilot's integration
    /// branch. The original branch is left untouched; uncommitted changes carry over as with a
    /// normal `git checkout -b`. Every autopilot merge then lands on this branch, not your main.
    static func createIntegrationBranch(projectPath: String, branch: String) async throws {
        let r = try await runGit(args: ["checkout", "-b", branch], workingDirectory: projectPath)
        guard r.success else { throw Error.commandFailed("git checkout -b \(branch)", stderr: r.stderr) }
    }

    /// Checks out an existing branch (used to re-enter the integration branch when resuming).
    static func checkoutBranch(projectPath: String, branch: String) async throws {
        let r = try await runGit(args: ["checkout", branch], workingDirectory: projectPath)
        guard r.success else { throw Error.commandFailed("git checkout \(branch)", stderr: r.stderr) }
    }

    // MARK: - Internals

    private struct Run {
        let success: Bool
        let stdout: String
        let stderr: String
    }

    private static func resolveGit() -> String? {
        let fm = FileManager.default
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func runGit(args: [String], workingDirectory: String) async throws -> Run {
        guard let gitPath = resolveGit() else { throw Error.gitNotFound }
        let collector = OutputCollector()
        do {
            let outcome = try await Subprocess.run(
                .path(FilePath(gitPath)),
                arguments: Arguments(args),
                environment: .inherit,
                workingDirectory: FilePath(workingDirectory),
                body: { execution, inputWriter, stdout, stderr in
                    try await inputWriter.finish()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await line in stdout.lines() {
                                await collector.appendStdout(line)
                            }
                        }
                        group.addTask {
                            for try await line in stderr.lines() {
                                await collector.appendStderr(line)
                            }
                        }
                        try await group.waitForAll()
                    }
                    _ = execution
                }
            )
            let success: Bool
            switch outcome.terminationStatus {
            case .exited(let code): success = (code == 0)
            case .signaled: success = false
            }
            return Run(success: success,
                       stdout: await collector.stdout,
                       stderr: await collector.stderr)
        } catch {
            throw Error.commandFailed("git \(args.joined(separator: " "))",
                                      stderr: error.localizedDescription)
        }
    }

    private static func parseShortStat(_ raw: String) -> DiffStat {
        // "<n> files? changed(, <n> insertions?(\+))?(, <n> deletions?(-))?"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return DiffStat(filesChanged: 0, insertions: 0, deletions: 0) }
        var files = 0, ins = 0, del = 0
        for chunk in trimmed.split(separator: ",") {
            let s = chunk.trimmingCharacters(in: .whitespaces)
            let parts = s.split(separator: " ")
            guard let first = parts.first, let n = Int(first) else { continue }
            if s.contains("file") { files = n }
            else if s.contains("insertion") { ins = n }
            else if s.contains("deletion") { del = n }
        }
        return DiffStat(filesChanged: files, insertions: ins, deletions: del)
    }
}

private actor OutputCollector {
    var stdout: String = ""
    var stderr: String = ""
    func appendStdout(_ line: String) { if !line.isEmpty { stdout += line + "\n" } }
    func appendStderr(_ line: String) { if !line.isEmpty { stderr += line + "\n" } }
}
