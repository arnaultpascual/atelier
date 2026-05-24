// SPDX-License-Identifier: MIT
import Foundation
import os

/// Initialises a directory as an Atelier project.
///
/// Creates:
/// - `backlog/config.yml` + `backlog/tasks/` + `backlog/archive/` (Backlog.md compatible)
/// - `.atelier/config.yml`
/// - appends `.atelier-worktrees/` and `.atelier/audit.jsonl` to `.gitignore`
///
/// Refuses to scaffold a path that isn't a directory. Idempotent: re-running on a
/// scaffolded project is a no-op for files that already exist (we never overwrite).
enum ProjectScaffolder {
    enum Error: Swift.Error, LocalizedError {
        case pathNotFound(String)
        case pathNotDirectory(String)
        case notAGitRepo(String)
        case writeFailed(String, underlying: Swift.Error)

        var errorDescription: String? {
            switch self {
            case .pathNotFound(let p): return "Path does not exist: \(p)"
            case .pathNotDirectory(let p): return "Not a directory: \(p)"
            case .notAGitRepo(let p): return "\(p) is not a git repository. Initialise it first with `git init`."
            case .writeFailed(let f, let u): return "Could not write \(f): \(u.localizedDescription)"
            }
        }
    }

    struct Report: Sendable {
        let created: [String]
        let alreadyPresent: [String]
        let gitignoreLinesAdded: [String]
    }

    private static let logger = Logger(subsystem: "app.atelier", category: "scaffolder")

    static func scaffold(at projectPath: String, projectName: String) throws -> Report {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: projectPath, isDirectory: &isDir) else {
            throw Error.pathNotFound(projectPath)
        }
        guard isDir.boolValue else {
            throw Error.pathNotDirectory(projectPath)
        }
        let root = URL(fileURLWithPath: projectPath, isDirectory: true)

        // Soft requirement: warn but don't block if not a git repo (some Atelier flows
        // — quick experiments — don't need git, even though worktrees obviously do).
        let gitDir = root.appendingPathComponent(".git", isDirectory: true)
        let hasGit = fm.fileExists(atPath: gitDir.path)
        if !hasGit {
            logger.warning("Scaffolding non-git project at \(projectPath, privacy: .public). Worktree-backed spawn will fail until `git init` is run.")
        }

        var created: [String] = []
        var alreadyPresent: [String] = []

        // backlog/
        let backlog = root.appendingPathComponent("backlog", isDirectory: true)
        try ensureDir(backlog, created: &created, alreadyPresent: &alreadyPresent, label: "backlog/")
        try ensureDir(backlog.appendingPathComponent("tasks", isDirectory: true),
                      created: &created, alreadyPresent: &alreadyPresent, label: "backlog/tasks/")
        try ensureDir(backlog.appendingPathComponent("archive", isDirectory: true),
                      created: &created, alreadyPresent: &alreadyPresent, label: "backlog/archive/")
        try ensureFile(
            backlog.appendingPathComponent("config.yml"),
            contents: backlogConfigYAML(projectName: projectName),
            created: &created, alreadyPresent: &alreadyPresent, label: "backlog/config.yml"
        )

        // .atelier/
        let atelierDir = root.appendingPathComponent(".atelier", isDirectory: true)
        try ensureDir(atelierDir, created: &created, alreadyPresent: &alreadyPresent, label: ".atelier/")
        try ensureFile(
            atelierDir.appendingPathComponent("config.yml"),
            contents: atelierConfigYAML(projectName: projectName),
            created: &created, alreadyPresent: &alreadyPresent, label: ".atelier/config.yml"
        )

        // .gitignore amendments
        let gitignore = root.appendingPathComponent(".gitignore")
        let added = try ensureGitignoreLines(at: gitignore, lines: [
            "",
            "# Atelier",
            ".atelier-worktrees/",
            ".atelier/audit.jsonl"
        ])

        return Report(created: created, alreadyPresent: alreadyPresent, gitignoreLinesAdded: added)
    }

    // MARK: - Helpers

    private static func ensureDir(
        _ url: URL,
        created: inout [String], alreadyPresent: inout [String], label: String
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            alreadyPresent.append(label)
            return
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            created.append(label)
        } catch {
            throw Error.writeFailed(label, underlying: error)
        }
    }

    private static func ensureFile(
        _ url: URL,
        contents: String,
        created: inout [String], alreadyPresent: inout [String], label: String
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            alreadyPresent.append(label)
            return
        }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            created.append(label)
        } catch {
            throw Error.writeFailed(label, underlying: error)
        }
    }

    /// Appends only the lines that aren't already in `.gitignore`. Creates the file if missing.
    private static func ensureGitignoreLines(at url: URL, lines: [String]) throws -> [String] {
        let fm = FileManager.default
        var existing: Set<String> = []
        var current = ""
        if fm.fileExists(atPath: url.path) {
            current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            existing = Set(current.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) })
        }
        var added: [String] = []
        var buffer = current
        for line in lines {
            if !existing.contains(line) {
                if !buffer.isEmpty && !buffer.hasSuffix("\n") { buffer += "\n" }
                buffer += line + "\n"
                if !line.isEmpty && !line.hasPrefix("#") {
                    added.append(line)
                }
            }
        }
        if buffer != current {
            do {
                try buffer.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw Error.writeFailed(".gitignore", underlying: error)
            }
        }
        return added
    }

    // MARK: - Templates

    private static func backlogConfigYAML(projectName: String) -> String {
        """
        # Backlog.md compatible config (interop with `backlog` CLI).
        version: 1
        project_name: "\(projectName)"
        default_status: "To Do"
        statuses:
          - "To Do"
          - "In Progress"
          - "Review"
          - "Done"
          - "Blocked"
        labels: []

        """
    }

    private static func atelierConfigYAML(projectName: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let today = formatter.string(from: Date())
        return """
        # Atelier project config — created \(today).
        version: 1
        project_name: "\(projectName)"
        default_model: claude-sonnet-4-6
        budget_usd_monthly: null

        # Project Profile slug — set automatically by Atelier when it can detect the stack
        # (Next.js, SwiftUI, Rust, etc.). Override here to lock in a specific profile.
        profile: generic

        # Claude permission baseline. Phase 0 ships an empty allow/deny; Phase 1 surfaces a
        # rules editor in the UI.
        permissions:
          allow: []
          deny:
            - "Read(./.env)"
            - "Read(~/.ssh/**)"
            - "Read(~/.aws/**)"
            - "Bash(rm -rf /)"
            - "Bash(git push --force*)"

        """
    }
}
