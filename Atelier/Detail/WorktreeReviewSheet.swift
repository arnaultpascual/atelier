// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import Observation
import SwiftUI
import os

/// Spawns an Opus 4.7 worker dedicated to writing a structured PR-style
/// review of the task's worktree. Read-only — uses bypassPermissions so the
/// review can grep / read / run `git diff` without prompting the user, but
/// can't write or modify files.
///
/// Output is collected as the worker's assistant turns stream in, then
/// rendered with `MarkdownView` so headings / code blocks / lists look like
/// a proper review.
struct WorktreeReviewSheet: View {
    let task: AtelierTask
    let project: Project
    let onClose: () -> Void

    @State private var session = ReviewSession()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.atelierDivider).opacity(0.6)
            content
        }
        .background(Color.atelierBackground)
        .task { await session.start(task: task, project: project) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(Color.atelierAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktree review")
                    .font(AtelierFont.eyebrow)
                    .foregroundStyle(Color.atelierAccent)
                Text(task.title)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .foregroundStyle(Color.atelierInk)
                    .lineLimit(2)
            }
            Spacer()
            statusBadge
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.atelierInkSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch session.status {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Opus 4.7 reading…")
                    .font(AtelierFont.captionMono)
                    .foregroundStyle(Color.atelierInkSecondary)
                if session.totalCostUsd > 0 {
                    Text(String(format: "$%.4f", session.totalCostUsd))
                        .font(AtelierFont.captionMono.weight(.semibold))
                        .foregroundStyle(Color.atelierAccent)
                }
            }
        case .completed:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.success)
                Text(String(format: "$%.4f", session.totalCostUsd))
                    .font(AtelierFont.captionMono.weight(.semibold))
                    .foregroundStyle(Color.atelierAccent)
                if session.outputText.isEmpty == false {
                    Button(action: copy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.atelierInkSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy review as markdown")
                }
            }
        case .failed:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.error)
                Text("Failed")
                    .font(AtelierFont.captionMono.weight(.semibold))
                    .foregroundStyle(Palette.error)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if session.outputText.isEmpty {
                    placeholder
                } else {
                    MarkdownView(source: session.outputText)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let err = session.errorMessage {
                    Text(err)
                        .font(AtelierFont.caption)
                        .foregroundStyle(Palette.error)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Reviewing the worktree with Opus 4.7…")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary)
            Text("Reading diff, walking changed files, drafting MR.")
                .font(AtelierFont.caption)
                .foregroundStyle(Color.atelierInkSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.outputText, forType: .string)
    }
}

// MARK: - Session state

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
        guard status == .idle else { return }
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
            model: "claude-opus-4-7",
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
