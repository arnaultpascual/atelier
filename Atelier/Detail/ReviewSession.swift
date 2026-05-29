// SPDX-License-Identifier: MIT
import Foundation
import Observation
import os

/// Drives the inline "Opus review" tab in `ReviewSection`. Spawns a read-only
/// Opus 4.8 worker that diffs the task's worktree against the base branch and
/// streams back a PR-style markdown review (summary / risks / tests / verdict).
///
/// Read-only by design: it routes through `WorkerRunner.runUngated` (claude's
/// own bypassPermissions) so the review can grep / read / `git diff` without
/// flooding the approval inbox, but never writes or modifies files. The streamed
/// text is rendered with `MarkdownView`; `ReviewSection` parses the trailing
/// "## Verdict" line into a verdict chip.
@MainActor
@Observable
final class ReviewSession {
    enum Status: Equatable { case idle, running, completed, failed }

    private(set) var status: Status = .idle
    private(set) var outputText: String = ""
    private(set) var totalCostUsd: Double = 0
    private(set) var errorMessage: String?

    nonisolated private static let logger = Logger(subsystem: "app.atelier", category: "worktree-review")

    func start(task: AtelierTask, project: Project) async {
        // Allow re-running from a finished/failed pass (the "Re-review" button);
        // only block while a review is already in flight.
        guard status != .running else { return }
        status = .running
        outputText = ""
        totalCostUsd = 0
        errorMessage = nil

        let branch = "worktree-\(task.id)"
        let worktreePath = URL(fileURLWithPath: project.path)
            .appendingPathComponent(".atelier-worktrees")
            .appendingPathComponent(task.id)
            .path

        guard FileManager.default.fileExists(atPath: worktreePath) else {
            status = .failed
            errorMessage = "Worktree \(worktreePath) is missing on disk."
            return
        }

        let prompt = Self.buildPrompt(task: task, branch: branch, projectPath: project.path)
        let runner = WorkerRunner()
        let invocation = WorkerRunner.Invocation(
            prompt: prompt,
            model: ModelRouter.latestOpus,
            apiKey: APIKeyResolver.resolve(),
            agentId: UUID(),
            settingsPath: "",                  // see below
            workingDirectory: worktreePath,
            additionalDirs: [project.path],
            includePartialMessages: false,
            maxTurns: 25,
            resumeSessionId: nil
        )

        // For a read-only review we don't want the approval inbox to gate every
        // Read/Grep/Bash call. We bypass our hook AND use claude's own
        // bypassPermissions mode by routing through a dedicated runner method.
        do {
            try await runReadOnly(runner: runner, invocation: invocation)
            status = .completed
        } catch {
            status = .failed
            errorMessage = error.localizedDescription
        }
    }

    private func runReadOnly(runner: WorkerRunner, invocation: WorkerRunner.Invocation) async throws {
        try await runner.runUngated(invocation: invocation,
                                    onEvent: { [weak self] event in
                                        await self?.ingest(event)
                                    },
                                    onStderr: { _ in })
    }

    private func ingest(_ event: StreamEvent) {
        switch event.kind {
        case .assistant(let text, _, _):
            if let t = text, !t.isEmpty {
                if !outputText.isEmpty { outputText += "\n\n" }
                outputText += t
            }
        case .result(_, let cost, _, _):
            if let c = cost { totalCostUsd = c }
        default:
            break
        }
    }

    private static func buildPrompt(task: AtelierTask, branch: String, projectPath: String) -> String {
        """
        You are reviewing a feature branch that was just completed by another \
        worker. Produce a thorough, MR-style review for the human developer to \
        read before merge.

        Branch under review: `\(branch)`
        Project root: `\(projectPath)`
        Original task: \(task.title)
        Task id: \(task.id)

        Steps:
        1. Run `git -C "\(projectPath)" log --oneline -10` to orient yourself in the project's recent history.
        2. Run `git -C "\(projectPath)" diff main..\(branch) --stat` to see the change shape.
        3. Run `git -C "\(projectPath)" diff main..\(branch)` for the actual patch. Read it carefully.
        4. For non-trivial changed files, open them and read the surrounding context (not just the hunk).
        5. If there are tests, look at them. If not, flag what should have been tested.

        Output a markdown review with EXACTLY these sections, in this order:

        ## Summary
        2-3 sentences. What this branch does, in plain English.

        ## Changes
        Walk through the meaningful changes. Use `path:line` references. Skip trivial / mechanical edits. Group by area when helpful.

        ## Risks
        Concrete concerns: security holes, perf regressions, edge cases missed, breaking changes, sneaky assumptions. Be specific — quote `file:line`. If you find none, say "None identified" — don't manufacture worries.

        ## Tests
        What's covered, what isn't. If tests were added, judge whether they exercise the new behavior. If none were added, list the test cases you'd ask for.

        ## Suggested followups
        What you'd ask the original author to address before merge. Numbered list. Each item one line.

        ## Verdict
        Exactly one of: APPROVE / CHANGES_REQUESTED / NEEDS_DISCUSSION.
        Followed by a one-line justification.

        Rules:
        - Caveman style. Imperative voice. No "I notice", no "great work", no preamble.
        - Quote `path:line` for every claim.
        - Don't repeat yourself between sections.
        - Don't write any files. This is read-only.
        - Total length: aim ~400 lines max.
        """
    }
}
