// SPDX-License-Identifier: MIT
import Foundation

/// A "cahier de test" for one finished feature: a two-part deliverable persisted as Markdown
/// under `.atelier/dossiers/<taskId>.md`. Part A (what the machine verified) is assembled in
/// Swift from real run results — never LLM-authored, so it can't be inflated. Part B (what a
/// human must verify) is one focused model pass. The rendered Markdown IS the artifact; the
/// struct is a thin carrier so a future PDF/HTML exporter has a seam.
struct TestDossier: Sendable {
    let taskId: String
    let taskTitle: String
    var costUsd: Double = 0
    let markdown: String
}

/// Disk I/O for dossiers — mirrors `writeAutopilotReport` / `loadPersistedReview` conventions.
/// `.atelier/dossiers/*.md` is tracked by default (like reviews/autopilot reports), so the
/// cahier de test becomes part of repo history and survives worktree removal.
enum TestDossierStore {
    static func directory(projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appendingPathComponent(".atelier/dossiers")
    }

    static func url(taskId: String, projectPath: String) -> URL {
        directory(projectPath: projectPath).appendingPathComponent("\(taskId).md")
    }

    @discardableResult
    static func persist(_ dossier: TestDossier, projectPath: String) -> URL {
        let dir = directory(projectPath: projectPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = url(taskId: dossier.taskId, projectPath: projectPath)
        try? dossier.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Returns the persisted dossier markdown for a task, or nil if none exists.
    static func load(taskId: String, projectPath: String) -> String? {
        let u = url(taskId: taskId, projectPath: projectPath)
        guard let s = try? String(contentsOf: u, encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    static func exists(taskId: String, projectPath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(taskId: taskId, projectPath: projectPath).path)
    }
}
