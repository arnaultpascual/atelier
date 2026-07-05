// SPDX-License-Identifier: MIT
import Foundation

/// App-level kill-switch for the MCP capability layer. This is a rollout guard,
/// not a user feature toggle. Default-ON as of Phase 4 (proven across phases);
/// set `atelier.mcpCapabilityEnabled` = false in UserDefaults to disable. When
/// off, no worker gets `--mcp-config` and the pure file+git contract is unchanged.
enum MCPCapability {
    static let defaultsKey = "atelier.mcpCapabilityEnabled"

    /// Defaults to `true` (unset → on). Set the `atelier.mcpCapabilityEnabled`
    /// UserDefaults bool to false to hard-disable the whole capability layer.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    // MARK: - Prompt augmentation
    //
    // The MCP tools only pay off if the worker knows to use them. These blocks are
    // appended to a worker's prompt when MCP is attached for a feature-scoped spawn,
    // turning a dormant capability into an active workflow. Additive — the file+git
    // contract in the rest of the prompt still holds.

    /// Guidance for a task build / iterate worker (feature `id`).
    static func taskWorkerGuidance(featureId: String) -> String {
        """
        ## Atelier tools — use them, don't work silently

        You're building one task of a larger feature. Atelier gives you live tools over MCP — call them, don't just work quietly:
        - **Report progress**: call `mcp__atelier__task_report_progress` with a percent (0–100) and a short note at each milestone, so the human watches this task advance on the board.
        - **Reference the original spec**: read the resource `atelier://feature/\(featureId)/spec` before you make design decisions, and again if you're unsure — it is the source of truth. Do NOT silently deviate from it.
        - **Shared files**: `atelier://feature/\(featureId)/attachments` lists the files the user shared with the brief (mockups, specs, screenshots) with their paths — Read them when your work touches what they describe (your task's own `## Attachments` section, when present, is the subset assigned to you).
        - **Record what you discover**: if the spec turns out impossible, or an API/library can't do what it assumed, call `mcp__atelier__spec_record_finding` (what you found + your workaround) so the sibling workers and the reviewer see it — don't just quietly work around it.
        - **Coverage**: before you finish, call `mcp__atelier__coverage_get` (soft aim ≥ 90%); use `mcp__atelier__coverage_uncovered` to see exactly which files still need tests.
        - **If you're stuck**: call `mcp__atelier__task_signal_blocked` with the reason (and what would unblock you) instead of guessing — it surfaces to the human immediately.
        - **When ready**: `mcp__atelier__task_update_status` → Review (Done happens on merge, not by you).

        These are additive: the git-worktree + strict-TDD workflow above still stands; the tools just keep Atelier in sync live and keep you anchored to the spec.
        """
    }

    /// Guidance for the managed synthesis / coverage-improvement worker running on
    /// a feature's integration branch.
    static func managedWorkerGuidance(featureId: String) -> String {
        """
        ## Atelier tools

        You're operating on this feature's integration branch. Use Atelier's MCP tools:
        - Read `atelier://feature/\(featureId)/spec` and judge the integrated work against the ORIGINAL demand.
        - Call `mcp__atelier__coverage_get` and `mcp__atelier__coverage_uncovered` to see coverage vs the soft 90% aim and exactly which files still need tests — target those files.
        - Record any discovered constraint or workaround with `mcp__atelier__spec_record_finding`.
        """
    }
}
