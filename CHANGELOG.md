# Changelog

All notable changes to Atelier are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-alpha.3] — 2026-05-27

Adds **Claude Opus 4.8** and 1M-context model variants.

### Added
- **Opus 4.8** is the new default Opus — the model router's "deep work" pick and Atelier's own
  Opus calls (autopilot review, brief decomposition, conflict resolution, on-demand review) use it.
- **1M-context variants** — *Opus 4.8 (1M)* and *Opus 4.7 (1M)* are selectable in every model
  picker (task, chat, quick spawn, project default). Enabled via the `[1m]` model suffix; a
  premium, manual opt-in (never auto-routed). The "Suggest" router knows them and prefers the
  non-1M ids unless a task needs a very large context.

### Changed
- The model list is trimmed to **Opus 4.8 · Opus 4.8 (1M) · Opus 4.7 (1M) · Sonnet 4.6 · Haiku
  4.5** (dropped Opus 4.6 and plain 4.7). Tasks/projects still pinned to an older id keep working.

[1.0.0-alpha.3]: https://github.com/arnaultpascual/atelier/releases/tag/v1.0.0-alpha.3

## [1.0.0-alpha.2] — 2026-05-27

A design + flow overhaul on top of the first alpha: the reused task-detail card is reworked for
every lifecycle stage, Chat gains quality-of-life, and Autopilot gets faster, clearer, and more
honest about cost.

### Added

- **Autopilot run grouping** — each finished run is grouped in the Done column as one card (its
  `atelier/autopilot-<timestamp>` integration branch + its tasks), persisted to
  `.atelier/autopilot/runs.json`. Open it for the combined diff (`base…integration`), per-task
  outcomes, and a one-click **Merge into `<base>`** (`--no-ff`; conflicts abort cleanly).
- **Inline Opus review** — the Review detail reviews in place (no modal), streams the verdict, and
  **saves the review** so it survives the merge into Done; the parsed verdict shows as a header
  chip. Autopilot's own reviews surface here too.
- **Conversation modes** — clean chat bubbles vs the raw event stream, in both Chat and the Review
  section, with per-message and whole-conversation copy.
- **Auto-titled chats** — a new conversation gets a concise Haiku-generated title from its first
  message, Claude-style.
- **CLAUDE.md reviewer** — draft / review a project's `CLAUDE.md` in a roomy sheet (rendered
  Preview / raw Edit) instead of a cramped inline box.
- **Task run durations** — the Review / Done recap shows how long a task took (summed worker time).

### Changed

- **Task-detail redesign** — the reused card is rethought per stage: To-Do is brief-as-hero with a
  compact meta strip (status / priority / model / depends-on / budget); Review and Done are calm
  recaps behind a single segmented inspector (Changes / Conversation / Opus review).
- **Autopilot reviews run in parallel** — a round is reviewed + auto-fixed concurrently (each
  worktree is independent); only the git merges stay serial.
- **Autopilot cost is complete** — Opus review and conflict-resolution spend now count toward the
  run total (previously only build + fix workers were metered).
- **Swarm** — running workers tick their elapsed time live, and the autopilot review / conflict
  phases now show as cards (they aren't TaskSpawner runs).
- **Approvals** — the deny action is labelled "Deny", with bulk "Accept all read-only" + a
  per-project filter; permission rules can be added from the Permissions tab.
- Flow fixes throughout: an in-app **Merge** button on Review with a protected-branch guard,
  Discard options that move/delete instead of stranding a task, editable Fill-kanban drafts,
  `git init` for non-git folders, "Create task from chat", Quick Spawn sharing the app model list,
  a real autopilot start-confirm + detached-HEAD guard, and a refreshed welcome screen.

### Fixed

- Deleting the selected task (e.g. Discard & delete) no longer leaves an empty ghost detail card.
- A Done task no longer mislabels itself "In review" or shows a duplicate "Done" badge.
- Usage totals say "recorded" (what Atelier has tracked) instead of the over-claiming "all-time".
- Chat web search is nudged so the model actually searches for real-time questions instead of
  replying that it has no access.

[1.0.0-alpha.2]: https://github.com/arnaultpascual/atelier/releases/tag/v1.0.0-alpha.2

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
