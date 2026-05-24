# Architecture

Atelier is a native macOS app (SwiftUI, Swift 6) that orchestrates one or more `claude`
subprocesses, each working in an isolated git worktree, and presents their activity through
a reactive UI. This document explains how the pieces fit together.

If you're new to the codebase, read this top to bottom once; afterwards the per-folder
structure under `Atelier/` will be self-explanatory.

## Contents

1. [Process model](#process-model)
2. [The two shells](#the-two-shells)
3. [Storage: disk is the source of truth](#storage-disk-is-the-source-of-truth)
4. [The worker lifecycle](#the-worker-lifecycle)
5. [Streaming: NDJSON → StreamEvent → AgentState](#streaming-ndjson--streamevent--agentstate)
6. [Approvals: the PreToolUse hook](#approvals-the-pretooluse-hook)
7. [Project profiles & skills](#project-profiles--skills)
8. [Model routing & budgets](#model-routing--budgets)
9. [Review & iterate](#review--iterate)
10. [Autopilot](#autopilot)
11. [Usage tracking](#usage-tracking)
12. [Chat](#chat)
13. [Tech stack](#tech-stack)
14. [Known limitations](#known-limitations)

## Process model

Atelier itself never talks to the Anthropic API. It drives the `claude` CLI as a subprocess
and reads its `stream-json` (NDJSON) output. Three kinds of process are involved:

```
┌─────────────────────────────────────────────────────────────┐
│ Atelier.app (SwiftUI, @MainActor)                             │
│                                                               │
│   AppStore ──(GRDB ValueObservation)── SQLite                 │
│   TaskSpawner ── ActiveRun[taskId] ── AgentState (live)       │
│   ApprovalQueue ◄── ApprovalSocketListener (Unix socket)      │
└───────┬───────────────────────────────────────────▲──────────┘
        │ spawn (swift-subprocess)                    │ decision
        ▼                                             │ (JSON line)
┌──────────────────────┐   PreToolUse hook   ┌────────┴───────────┐
│ claude -p             │ ──── (stdin JSON) ─►│ AtelierApprovalHelper│
│ --output-format        │ ◄─── (exit/JSON) ──│  (stdio binary)     │
│   stream-json          │                    └─────────────────────┘
│ (runs in git worktree) │
└──────────────────────┘
```

- **Atelier.app** — the SwiftUI app. Almost all of it runs on the `@MainActor`; concurrency
  is pushed to the edges (the subprocess runner is an `actor`, DB access is `async`).
- **`claude` workers** — one subprocess per spawn, launched via
  [swift-subprocess](https://github.com/swiftlang/swift-subprocess), running with its working
  directory set to a git worktree.
- **`AtelierApprovalHelper`** — a tiny stdio binary that `claude` invokes as a `PreToolUse`
  hook on every tool call. It relays the request to Atelier over a Unix-domain socket and
  translates the user's decision back into the hook protocol. See
  [Approvals](#approvals-the-pretooluse-hook).

## The two shells

The app has two UI surfaces:

- **`MainView`** — the primary window. A `NavigationSplitView` with a Workspaces sidebar on
  the left and a center pane that switches between **Chat**, **Swarm**, **Approvals**,
  **Usage**, and a project's **Kanban board**. Selecting a task opens a detail sheet.
- **`ContentView`** — a single-spawn console reachable from the **Quick Spawn** window
  (**⌘⇧Q**). It fires one ad-hoc worker against a folder you pick, with no project or task.
  It predates the main shell and shares the underlying `Orchestrator`/`WorkerRunner` plumbing.

Both are wired up in `AtelierApp.swift`, which also owns the app-wide singletons
(`AppStore`, `ApprovalServer`, `TaskSpawner`, `ApprovalQueue`, `ChatSpawner`) as `@State`.

## Storage: disk is the source of truth

State persistence (`Atelier/Storage/`) follows one rule: **task content lives in your repo as
Markdown; the database is a queryable index of it.**

- A task is a file at `<project>/backlog/tasks/<id>-<slug>.md` with YAML frontmatter and a
  Markdown body (a [Backlog.md](https://github.com/MrLesk/Backlog.md)-compatible shape).
  `BacklogMD` reads/writes these and **round-trips unknown frontmatter keys**, so other tools
  can annotate the same files without Atelier clobbering them.
- `AppStore.importTasksFromDisk(project:)` reconciles the `backlog/tasks/` directory into the
  DB (add / update / remove). It runs when you add a project and on manual refresh.
- Everything else — workspaces, projects, agent runs, approvals, learned policies, chat rooms
  — lives only in SQLite.

The database is a single file at `~/Library/Application Support/Atelier/atelier.sqlite`, opened
through [GRDB](https://github.com/groue/GRDB.swift) in WAL mode (`Database.swift`). Schema
migrations are registered in `Schema.swift`:

| Migration | Adds |
|-----------|------|
| `v1` | `workspace`, `project`, `task`, `agent`, `approval`, `policy`, `event` + indexes |
| `v2_attachments` | `task.attachments` (JSON array of relative paths) |
| `v3_chat_room` | `chat_room` |

Column names are **camelCase** to line up with Swift property names and GRDB's `belongsTo`
foreign-key generator. In `DEBUG` builds, `eraseDatabaseOnSchemaChange` is on, so editing the
schema during development resets the DB instead of failing the migration.

### `AppStore` — the reactive façade

`AppStore` is `@MainActor @Observable`. On init it starts GRDB `ValueObservation` streams for
workspaces, projects, tasks, and chat rooms; each stream pushes fresh values onto the main
actor, and SwiftUI views read the published arrays directly. Mutations (`createTask`,
`updateTaskStatus`, …) are `async`: they write to disk and/or the DB, and the observation
propagates the change back into the view model. There is no manual "reload" — writes and reads
are decoupled through the observation.

## The worker lifecycle

A task spawn is owned end-to-end by `TaskSpawner.execute(...)` (`Atelier/Worker/`). Each spawn
is one `ActiveRun` (held in `runs[taskId]`), bundling the `Agent` DB record, the live
`AgentState`, and the Swift `Task` driving the subprocess.

1. **Worktree** — `GitService.ensureWorktree(projectPath:taskId:)` creates (or reuses)
   `<repo>/.atelier-worktrees/<taskId>` on branch `worktree-<taskId>`. It's idempotent:
   if the branch already exists it re-attaches instead of passing `-b`. The
   `.atelier-worktrees/` directory is gitignored.
2. **Skills** — `SkillBundler.installSkills(...)` copies the universal skills plus the project
   profile's skills into `<worktree>/.claude/skills/`, where `claude` discovers them
   automatically.
3. **Agent row** — an `Agent` record is inserted, capturing the worktree, branch, and model.
   It's updated live as the run progresses (session id, cost, tokens, terminal status).
4. **Approval socket** — `ApprovalSocketListener.start()` opens a per-spawn Unix-domain socket
   and returns its path; `MCPConfig.writeTemporaryConfig(...)` writes a settings JSON that
   points the hook at it. Per-project + profile permission rules are loaded into the
   `ApprovalQueue`.
5. **Prompt** — `TaskSpawner.buildPrompt(...)` assembles the task title, metadata, description,
   attachment paths, and a **House rules** block telling the worker it's in a worktree and must
   not `merge`/`push`/`rebase` — the user reviews and merges manually.
6. **Launch** — `WorkerRunner.run(...)` spawns:

   ```
   claude -p --debug-file <tmp>.log --output-format stream-json --verbose \
          --model <model> --max-turns 80 \
          --settings <settings>.json \              # gated mode: installs the PreToolUse hook
          --add-dir <attachments> <projectRoot> --  # variadic; `--` terminates the list
          "<prompt>"
   ```

   with `ATELIER_AGENT_ID` (and `ANTHROPIC_API_KEY` if a key is in play) added to the inherited
   environment. The worker's working directory is the worktree.
7. **Finalize** — when the subprocess exits, the `Agent` row is persisted with final status,
   cost, and tokens; a successful task is promoted To Do/In Progress → **Review**; the temp
   settings file and socket are cleaned up.

`WorkerRunner` has three execution modes:

| Mode | Flags | Used by |
|------|-------|---------|
| `gated` | `--settings <hook config>` | task workers (every tool call is gated) |
| `ungated` | `--permission-mode bypassPermissions` | the read-only "Review with Opus" pass |
| `chat` | `bypassPermissions` + `--disallowed-tools …` | Chat (no tools unless opted in) |

## Streaming: NDJSON → StreamEvent → AgentState

`claude --output-format stream-json` emits one JSON object per line. `NDJSONLineDecoder`
maps each line to a `StreamEvent` — a stable enum (`system`, `assistant`, `user`/tool-result,
`result`, `streamEvent`, `rateLimit`, `malformed`, `unknown`). Parsing is **permissive**:
unrecognized shapes degrade to `.unknown` rather than throwing, so the app tolerates Claude
Code version drift. The stdout line buffer is lifted to 16 MB because a single `Read`
tool-result can arrive as one very large line.

`AgentState` (`@MainActor @Observable`) ingests events into the live view model: accumulating
assistant text and tool calls, capturing the session id from the first `system` event, summing
`total_cost_usd` and token usage from `result` events, and tracking status
(`idle → starting → running → completed | failed`). `TaskSpawner` additionally mirrors cost,
tokens, and session id into the `Agent` record via `absorbStreamEventIntoAgent`.

## Approvals: the PreToolUse hook

This is the most non-obvious part of the system, and the design exists for a concrete reason.

**What didn't work.** The natural fit is MCP's `--permission-prompt-tool mcp__server__tool`:
expose an approval tool from a local MCP server and let `claude` call it. But `claude` validates
that flag **synchronously at startup**, before any MCP server — HTTP or stdio — has finished
connecting. The validator never sees the tool, and the spawn fails. (This was confirmed against
Claude Code 2.1.78; an early version of Atelier used Hummingbird + the swift-sdk MCP server and
hit this race repeatedly.)

**What works.** `claude` also supports **hooks** declared in a settings file, and those are
loaded from the settings JSON in a single synchronous pass — no race. So Atelier writes a
settings file with a `PreToolUse` hook:

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "*",
      "hooks": [{
        "type": "command",
        "command": "/path/to/AtelierApprovalHelper --agent-id <uuid> --socket <path>",
        "timeout": 3600
      }]
    }]
  }
}
```

On each tool call `claude` runs `AtelierApprovalHelper`, passing the tool name and input as JSON
on **stdin**. The helper:

1. connects to Atelier's per-spawn Unix-domain socket,
2. writes a newline-delimited JSON request (`agent_id`, `tool_name`, `input_json`, …),
3. blocks on a single response line,
4. translates it into the hook protocol on **stdout** and exits 0:
   - allow → `{"decision":"approve","reason":"…"}`
   - deny → `{"decision":"block","reason":"…"}`

On the Atelier side, `ApprovalSocketListener` accepts the connection and enqueues an item on the
`ApprovalQueue`, which is what the **Approvals** inbox renders. Before showing it to you, the
queue evaluates the request against learned/project rules (`PermissionRule`,
`ProjectPermissionStore`, the `policy` table): a matching rule auto-decides; otherwise it waits
for you. If the socket is unavailable the helper **fails open** (allow) by default — tune with
`--deny-on-failure`.

The helper is built as a separate `tool` target and copied into
`Atelier.app/Contents/MacOS/AtelierApprovalHelper` by a post-build script in `project.yml`.
`ApprovalServer` is now just a readiness flag that checks the helper is present in the bundle;
it no longer hosts any protocol stack.

## Project profiles & skills

`Atelier/Profiles/` detects what kind of project a folder is and tailors agent behavior.

- `ProjectProfileDetector.detect(at:)` inspects top-level marker files and returns one of nine
  profiles: `swift-apple`, `web-nextjs`, `node-backend`, `python`, `rust`, `go`,
  `android-kotlin`, `docs`, or `generic`. Detection is cheap (one directory listing plus an
  optional `package.json` parse) and ordered most-specific-first.
- Each profile carries a **default model** (e.g. `swift-apple` → Opus 4.7, `docs` → Haiku 4.5).
- `SkillBundler` installs `SKILL.md` files into a worktree's `.claude/skills/`. Skills ship in
  the app bundle under `Resources/Skills/`: `universal/` (loaded for every project) and
  `profiles/<id>/` (loaded only for the matching profile). Installation is idempotent, so skill
  edits propagate on the next spawn. The **Skills** tab in Settings lists everything bundled.

A `SKILL.md` is YAML frontmatter (`name`, `description`) plus a Markdown body of guidance.

## Model routing & budgets

`ModelRouter.resolve(task:projectDefault:)` picks a model in priority order: an explicit
per-task `workerModel`, else the project default, else a rule of thumb based on the task's
labels and size (heavy/architectural work → Opus, trivial/chore → Haiku, otherwise Sonnet).
The UI also offers a "Suggest" action that asks Haiku to recommend a model for a given task.

Budgets are enforced in `TaskSpawner.enforceBudget`: after every `result` event, if the run's
cumulative `total_cost_usd` has crossed the task's cap, the worker's `Task` is cancelled
(SIGTERM via swift-subprocess) and the run is flagged "budget cap reached". Enforcement is
**post-hoc** — a single expensive turn can overshoot before the next event arrives.

## Review & iterate

When a task completes it moves to **Review** (`Atelier/Detail/`). `ReviewSection` shows the
worker's transcript (live, or reloaded from `claude`'s persisted JSONL via `SessionReader`) and
the git diff. `GitService.diffStat` / `changedFiles` compute changes against the **merge-base
with `HEAD`**, and also surface uncommitted/untracked files left in the worktree. From here you
can:

- **Discard** the worktree and branch,
- **Review with Opus** — spawn a read-only `ungated` Opus pass that reads the diff and writes an
  MR-style review,
- **Iterate** — `TaskSpawner.iterate(...)` resumes the same `claude` session with
  `--resume <sessionId>` and a follow-up message, seeding the live state with the prior run's
  cost/tokens so totals accumulate,
- **Mark as Done**.

You always merge by hand; Atelier never touches your default branch.

## Autopilot

Review & iterate is hands-on: you drive each task through build → review → fix → merge yourself.
**Autopilot** (`Atelier/Autopilot/`) runs that whole loop unattended for up to *N* batches. It is
the single most dangerous feature in the app — unsupervised code execution that auto-commits and
auto-merges — so its design is guardrails-first.

`FeatureBuildRunner` is one app-wide `@MainActor @Observable` orchestrator keyed by project
(mirroring `TaskSpawner.runs`). It owns an `AutopilotRun` per project and **reuses** the proven
pieces rather than re-implementing them: `TaskSpawner` for build/iterate, `AIAssistant` for the
structured review and conflict resolution, `GitService` for merge, and `ExecutionPlanner` for
rounds. Each task carries a live `TaskPhase` (`queued → building → reviewing → fixing(pass) →
merging → resolvingConflict → done | blocked`) that drives the board chips and the run pill.

The loop, per round:

1. **Plan** — `ExecutionPlanner.runnableNow(...)` recomputes the wave of To Do tasks whose
   dependencies are all `.done`. The planner is the *single source of truth* for waves, shared with
   the Kanban board and the Fill-kanban sheet so the UI and autopilot never disagree.
2. **Build (parallel)** — every runnable task spawns concurrently via
   `TaskSpawner.spawnAndAwait(..., autopilot: true)`. Real parallelism (subprocesses run off the
   main actor); awaited as unstructured `@MainActor` tasks.
3. **Integrate (serial)** — sorted by priority then id (merges share the branch + index), each
   finished task goes through `reviewFixMerge`:
   - **Structured review** — `AIAssistant.reviewWorktree` runs an Opus pass that returns a
     `ReviewReport` (`verdict`, `summary`, `findings[{severity, file, line, summary, suggestedFix}]`).
     Severity is `critical | major | minor | cosmetic`; only **critical/major** are *blocking*. An
     unparseable/failed review degrades to "block" — autopilot never merges a review it can't read.
   - **Fix (capped)** — while there are blocking findings and `pass < 2`, it resumes the worker's
     session (`iterateAndAwait`) with a message listing **only** those findings ("fix only these,
     don't refactor, keep build/tests green, commit") and re-reviews. Minor/cosmetic findings are
     never auto-fixed.
   - **Merge** — `commitWorktree` finalizes any leftover changes, then `GitService.merge(... )`
     does a local `git merge --no-ff` into the run's **integration branch**. On conflict, a
     dedicated `AIAssistant.resolveMergeConflict` worker resolves it in-place (retry once), else
     `git merge --abort` + block.

**Locked design decisions:**

- **Approvals — deny wins, else auto.** Autopilot workers stay *gated*: `ApprovalQueue` evaluates
  per-project/profile rules first, so an explicit **deny still denies**; only calls not denied are
  auto-accepted (`setAutopilot(true, forAgent:)`). There is no silent full-bypass.
- **Merge — local `--no-ff`, never push.** Every merge is one explicit, revertable commit onto a
  fresh feature branch `atelier/autopilot-<timestamp>` created off your current branch — your
  original branch is **never** touched and nothing is ever pushed. The worker prompt still forbids
  workers from running merge/push/rebase themselves; the runner merges, in the main repo.
- **Failure — block & continue.** A task that fails to build, stays blocking after the fix cap, or
  whose conflict can't be resolved is marked **Blocked** (its worktree kept) and the run continues
  other independent branches. Its dependents simply never become runnable, so they stay in To Do.

**Guardrails:** refuses to start on a detached HEAD; per-task fix cap (2) and conflict-resolve cap
(1); optional global spend cap checked before each spawn; a per-run round ceiling against runaway
loops; explicit start confirmation framed as unsupervised autonomous execution. Each terminal task
writes a human-readable report to `<repo>/.atelier/autopilot/<taskId>.md` (verdict, findings by
severity, outcome) surfaced in the task detail so the review stays consultable after the run.

**Usage-limit pause/resume.** If a worker stops on an Anthropic usage/rate limit
(`AgentState.looksUsageLimited` — a structured `rate_limit_event`, or signatures like "usage limit"
/ "resets at" / "429" in the last error or stderr) it is *not* the task's fault, so autopilot
**pauses** the whole run (`Status.paused`) instead of blocking-and-cascading. A half-built task
rolls back to To Do; one already in Review stays there. **Resume** continues on the *same* feature
branch — it re-checks it out, re-integrates anything left in Review, then builds the rest. In a
normal (non-autopilot) swarm the same detector relabels the stopped card "Usage limit" and offers a
one-click **Relaunch**.

State is **in-memory for v1**: the source of truth survives a crash anyway (task status in
Markdown + DB, each worker writes a normal `Agent` row so Usage attribution is free, branches
persist on disk). On quit, autopilot stops and phases re-derive from task status.

## Usage tracking

The **Usage** dashboard (`Atelier/Usage/`) unifies two sources into a single `UsageRecord`
stream:

- **Atelier agents** — exact `total_cost_usd` from `Agent` rows.
- **Claude Code history** — `ClaudeHistoryScanner` walks `~/.claude/projects/*/*.jsonl` (every
  session on the machine) and emits **one record per assistant message**, timestamped to that
  message, with cost **estimated** from token counts via `ClaudePricing`. Records are deduped by
  `message.id + requestId` so resumed/compacted sessions aren't double-counted, and records that
  match an Atelier run (by session id) defer to the exact figure.

Per-message attribution is what makes "today", streaks, and the heatmap correct even for long
sessions that span midnight. `UsageLimitsService` optionally fetches live subscription
utilization (5-hour / weekly limits) using Claude Code's stored OAuth token, read **read-only**
from the Keychain and **opt-in**. `ClaudePricing` rates are hard-coded to Anthropic's published
numbers and need a manual bump when pricing changes.

## Chat

`Atelier/Chat/` is a free-form conversation surface that isn't tied to a project. Rooms persist
as `chat_room` rows with a scratch directory; sessions resume via their `sessionId`. Chat runs
`WorkerRunner.runChat`, which disables all tools by default (file reads and web search are
opt-in per room). It reuses the same NDJSON pipeline as workers but with a simpler state model
(no approvals, no task state machine).

## Tech stack

| Dependency | Why |
|------------|-----|
| [swift-subprocess](https://github.com/swiftlang/swift-subprocess) | spawn & stream `claude` and `git` |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite + reactive `ValueObservation` |
| [Yams](https://github.com/jpsim/Yams) | YAML frontmatter in task files and permission rules |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | generate the Xcode project from `project.yml` |

The project is Swift 6 with `SWIFT_STRICT_CONCURRENCY: minimal`, hardened runtime on, and dead
code stripping enabled. `git` operations shell out to the user's `git` binary rather than
linking libgit2 — simpler, and performance hasn't been a concern.

## Known limitations

- **No automated tests yet.** The codebase is structured for testability (pure parsers,
  `actor`-isolated IO) but there's no suite. This is the top contribution opportunity.
- **Budget enforcement is post-hoc** (see above).
- **Session recovery is best-effort** — if a session id is lost, `SessionReader` falls back to
  the most recent JSONL in the worktree's session directory.
- **Profiles and skills are compiled in** — there's no user-defined-profile UI yet.
