# Changelog

All notable changes to Atelier are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-alpha.1] — 2026-05-24

First public release. Atelier graduates from a single-agent proof of concept into a full macOS
studio for orchestrating parallel Claude Code agents.

### Added

- **Workspaces & projects** — organize repositories, with automatic stack detection across nine
  project profiles (Swift/Apple, Next.js, Node, Python, Rust, Go, Android/Kotlin, docs, generic).
- **Kanban backlog** — tasks stored as Markdown in `<repo>/backlog/tasks/*.md` (disk is the
  source of truth), across five columns. Includes AI task decomposition of a brief via Opus 4.7,
  dependency-aware execution waves, and batch-spawning a round of unblocked tasks.
- **Parallel agents** — each task runs a `claude` worker in its own git worktree
  (`worktree-<taskId>`), streaming a live NDJSON timeline of reasoning, tool calls, results, and
  cost into an inspector.
- **Swarm view** — a dashboard of every live and recently-finished agent.
- **Human-in-the-loop approvals** — every tool call is gated through a `PreToolUse` hook and an
  in-app inbox, with per-project learned permission rules.
- **Per-project auto-approve levels** — opt a project into auto-approving read-only tools,
  everything-but-Bash, or everything; explicit deny rules still take precedence.
- **Worktree review** — per-task git diff, an Opus-powered read-only code review, session
  iteration via `--resume`, and manual merge (agents never `merge`/`push`/`rebase`).
- **Autopilot** — run the whole backlog hands-off for *N* batches: build a round in parallel →
  structured Opus review → auto-apply only critical/major fixes (capped) → local `--no-ff` merge
  into a fresh `atelier/autopilot-<timestamp>` branch → resolve conflicts with a dedicated worker →
  advance. Approvals stay gated (explicit denies still win, everything else is auto-accepted);
  your base branch is never touched and nothing is pushed; a failed/stuck task is *blocked &
  continue*. Includes a dependency editor + batch preview, per-task reports persisted to
  `.atelier/autopilot/`, a global spend cap, and **usage-limit pause/resume** — a worker stopped by
  an Anthropic rate limit pauses the run (or relabels its swarm card "Usage limit") with a Resume /
  Relaunch button that continues on the same branch. See
  [ARCHITECTURE.md](ARCHITECTURE.md#autopilot).
- **Project profiles & skills** — matching `SKILL.md` guidance is injected into each worker's
  `.claude/skills/` automatically; browsable in Settings.
- **Chat** — free-form Claude conversations, no project required, with opt-in file/web access.
- **Usage dashboard** — cross-project cost and token analytics combining Atelier's own runs with
  scanned Claude Code history (per-message attribution, dedup, heatmap), plus opt-in live
  subscription-limit tracking.
- **Model routing & budgets** — per-task / per-project / rule-based model selection, an AI
  "Suggest" action, and spend caps that auto-abort a worker when crossed.
- **Dual authentication** — works with a Claude subscription (Pro / Max / Enterprise via
  `claude auth`) or an Anthropic API key (Keychain or environment).
- **Quick Spawn** window (**⌘⇧Q**) — fire a single ad-hoc worker against any folder.
- **First-launch Setup Assistant** — verifies the `claude` CLI, `git`, and authentication are in
  place and guides you through anything missing.

### Changed

- HITL approvals are driven by a `PreToolUse` hook and a stdio helper
  (`AtelierApprovalHelper`) over a Unix-domain socket, replacing the earlier in-process MCP
  server. This sidesteps a startup race where `claude` validates `--permission-prompt-tool`
  before any MCP server has connected. See
  [ARCHITECTURE.md](ARCHITECTURE.md#approvals-the-pretooluse-hook).

### Removed

- Dropped the now-unused `Hummingbird` and `swift-sdk` (MCP) dependencies that backed the old
  approval transport, shrinking the dependency graph.

[1.0.0-alpha.1]: https://github.com/arnaultpascual/atelier/releases/tag/v1.0.0-alpha.1
