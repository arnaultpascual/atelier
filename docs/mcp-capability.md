<!--
MIT License — Copyright (c) 2026 Arnault Pascual
-->

# MCP capability layer — design doc (Phase 0)

> Status: **Phase 0 complete & validated (D1–D3 resolved) — proceeding to Phase 1.**
> Branch: `feat/mcp-capability` → `develop`. Verified against `claude` **2.1.190**.

## 1. Goal

Give Claude workers a **typed capability API + on-demand context + a real-time back-channel** to Atelier's domain, on top of the existing file+git contract (which stays the source of truth and the fallback). A local **stdio MCP server** (`atelier`) is passed to every *feature-scoped* worker spawn and bridges over a Unix socket to the running app.

Priority order (from the brief): (1) live build progress/blocks in the kanban, (2) structured brief-building, (3) always-referenceable original spec + living brief as resources, (4) data-driven TDD/coverage, (5) server-served prompt templates.

---

## 2. Phase 0 verification — the blocking questions, answered empirically

I built a toy stdio MCP server (`initialize`/`tools/list`/`tools/call`/`resources/*`/`prompts/*`) and drove it through `claude -p` under every relevant posture.

| # | Posture | Result |
|---|---------|--------|
| 1 | `--mcp-config <file>`, `--permission-mode default`, nothing pre-allowed | server **connects** (`status: connected`), tool exposed as `mcp__atelier__ping`, but the call is **BLOCKED**: *"you haven't granted it yet"* |
| 2 | `default` + `--allowedTools "mcp__atelier"` (server-wide) | ✅ tool call succeeds |
| 3 | `--permission-mode bypassPermissions` | ✅ tool call succeeds |
| 4 | resource read (built-in `ReadMcpResourceTool {server, uri}`) | ✅ returns our `contents[]` |
| 5 | `--mcp-config` **+ `--settings` hook** together, `default` mode | ✅ works — **the PreToolUse hook fires for `mcp__atelier__ping` and `ReadMcpResourceTool`**; its `permissionDecision:"allow"` auto-approves them |
| 6 | MCP server binary **missing** | ✅ `status: failed`, worker still completes normally (exit 0) — file+git fallback holds |
| 7 | `--disallowed-tools "ToolSearch" "Agent"` | ✅ MCP tool is called **directly** (no ToolSearch hop needed) |
| 8 | tool named with a **dot** (`task.report_progress`) | ❌ **silently dropped** — never appears in the tool list. Dots are invalid (API name regex `^[a-zA-Z0-9_-]{1,64}$`). Underscore variant works. |

**Naming rule (from Test 8):** tool names use **underscores**, not dots: `task_report_progress`, `brief_append_section`, `spec_record_finding`, `coverage_get`, `wave_mark_done`, … (`mcp__atelier__` prefix is 14 chars; keep the suffix ≤ 50).

### The one assumption that was wrong
The brief (§2.5) hoped stdio servers via `--mcp-config` would be **auto-trusted** in headless `-p`. **They are not** — a bare `mcp__atelier__*` call is denied in `default` mode. This is *not* a blocker; three levers make our own tools pass silently (see §6). It does mean "MCP = capability only, never permissions" (§2.1) needs a nuance: we must **explicitly allow our own tool prefix**, but we do **not** change the approval *flow* — we add a prefix to the allow set / hook auto-approve. Guardrail intact.

### Other empirical facts
- `--mcp-config` + `--strict-mcp-config` + `--settings` **compose cleanly** — all three coexist.
- Tools surface as `mcp__atelier__<tool>`; resources need the built-in `ReadMcpResourceTool`.
- The **race that killed `--permission-prompt-tool`** (claude validated the permission tool *synchronously at startup, before* MCP connected) does **not** bite capability tools: tools are called lazily and worked in every test. The only residual requirement is that `AtelierMCPServer` starts fast (it's a thin socket client — fine).

---

## 3. Recon — resolved open questions (all HIGH confidence)

| Q | Answer | Anchor |
|---|--------|--------|
| **Where does the "original spec" live?** | **Nowhere.** A feature's spec is the single **living** `brief.md`, rewritten in place each chat turn, at `~/Library/Application Support/Atelier/chat-scratch/<Feature.briefRoomId>/brief.md`. No snapshot, no `originalSpec` column, no first-message capture. `briefRoomId` is `nil` until the Brief stage. **→ an immutable "original" must be *created* (snapshot) if we want one.** | `ChatRoom.swift:62`, `Feature.swift:12-26,18` |
| **Does a spawn know its featureId?** | **No.** Zero `featureId` refs in `WorkerRunner`/`TaskSpawner`. It lives only on `Task.featureId` (`Task.swift:23-25`), used at the orchestration layer. The only worker↔app correlation today is the `ATELIER_AGENT_ID` env var + the socket path (first 8 chars of agentId). **→ must thread `featureId`/`taskId` into `WorkerRunner.Invocation`.** | `WorkerRunner.swift:38-71,196`, `FeatureBuildRunner.swift:145-165` |
| **Task `.md` vs DB — who's canonical?** | **`.md` is source of truth; DB is a rebuildable cache.** `AppStore.updateTask` rewrites the `.md` (extras-preserving) **first**, then the DB row. Only `BacklogMD.serialize/write` touches frontmatter, only via `AppStore`. **→ the bridge must route status changes through `AppStore.updateTaskStatus`, never write files itself.** | `AppStore.swift:437-466`, `Task.swift:5-9,64`, `BacklogMD.swift:162,212` |
| **Test target?** | **None exists — must create `AtelierTests`.** Only two targets (`Atelier`, `AtelierApprovalHelper`); scheme `test` action has empty `<Testables>`. | `project.yml:31-96,105-106` |
| **Coverage source?** | **dotnet only.** The sole `coverageCommand` is dotnet's `--collect:"XPlat Code Coverage"` → Cobertura XML, parsed by `CoberturaParser` (root line-rate, no per-file). Every other mode → `coverageTarget == nil`. `90%` is a *computed fallback* (`coverageTargetPct ?? (coverageCommand != nil ? 90 : nil)`), materializing only for dotnet. Coverage is **never persisted**. | `ProjectProfile.swift:234,58`, `DossierBuilder.swift:205-233` |

### Corrections to the brief's premises
1. **Autopilot workers are `.gated`, not `bypassPermissions`.** Normal task spawns run `--settings` + the PreToolUse hook with the approval queue in auto-accept (`setAutopilot(true)`). Only review (`.ungated`) and `.chat` use `bypassPermissions`; `--disallowed-tools` is `.chat`-only. **→ autopilot MCP tools flow through the hook (Test 5 path), which must auto-approve `mcp__atelier__*`.** (`WorkerRunner.swift:143-170`)
2. **"Always reference the original" is currently impossible** — there is no original to reference (see Q1). Delivering the locked principle *requires* introducing a snapshot.
3. **Coverage tools will honestly return "not measured"** for non-dotnet modes at launch.

---

## 4. Architecture

Near-verbatim structural clone of the approval bridge, with the two protocol halves swapped:

```
claude worker
  │  (a) mcp__atelier__task.report_progress / ReadMcpResourceTool   ← MCP JSON-RPC over stdio
  ▼
AtelierMCPServer  (new `type: tool` executable, zero packages, Foundation-only)
  │  (b) length-agnostic NDJSON request/response                    ← Unix socket /tmp/at-mcp-<8hex>.sock
  ▼
AtelierBridgeListener  (new actor, mirrors ApprovalSocketListener)
  │  (c) await MainActor.run { try await store.… }
  ▼
AppStore (@MainActor, single GRDB writer) ──ValueObservation──▶ kanban / feature UI updates live
```

New pieces, each anchored to the pattern it clones:
- **`AtelierMCPServer/main.swift`** — clones `AtelierApprovalHelper/main.swift` (`connectSocket`/`writeAll`/`readLine` POSIX primitives, `HelperArgs.parse`). Adds a hand-rolled MCP JSON-RPC layer on stdin/stdout. **No** GRDB/Yams (mirror the helper's zero-package profile).
- **`Atelier/MCP/MCPServerConfig.swift`** — sibling of `MCPConfig.swift`; `writeTemporaryConfig(...)` emits the `--mcp-config` JSON (`{"mcpServers":{"atelier":{"command":<AtelierMCPServer path>,"args":["--socket",…,"--feature-id",…,"--task-id",…,"--project-path",…]}}}`). Binary resolved via a `helperPath()`-style sibling lookup.
- **`Atelier/MCP/AtelierBridgeListener.swift`** — actor cloning `ApprovalSocketListener` (bind → accept → read loop → decode → `@MainActor` hop → write). Constructed per-spawn in `TaskSpawner`, `start()` before spawn / `stop()` after.
- **spawn wiring** — add `featureId`/`taskId` to `WorkerRunner.Invocation`; append `--mcp-config <path> --strict-mcp-config` in `execute(...)` at `WorkerRunner.swift:135-142`, composing with the existing `--settings`. Gated by **scope** (see §6/§7), not the shared spawner API.

### Guardrails honored
- **stdio only**, no HTTP. **App = single GRDB writer**; server holds **no** DB handle. **Feature-scoped**: no `--mcp-config` for non-feature spawns. **Additive** migrations only. New binary **embedded + signed** exactly like `AtelierApprovalHelper` (manual `cp` postBuildScript — XcodeGen `embed` mislocates `tool` products to `Contents/Resources`).

---

## 5. Socket protocol (app ↔ server)

- **Framing:** newline-delimited **compact** JSON (matches the approval bridge; JSON escapes inner newlines, so multiline `brief.md` is safe on one line). Fix the approval bridge's write weakness by using a proper `writeAll` loop for large payloads (resource bodies).
- **Path:** `/tmp/at-mcp-<first8ofAgentId>.sock` — **must** stay under the 104-byte `sun_path` limit (same constraint as `/tmp/at-ap-…`).
- **Typed Codable messages** (the new bridge upgrades from the helper's untyped `[String:Any]`), in a **shared source file** compiled into both the app and the server target:

```swift
struct BridgeRequest: Codable {           // server → app
  let id: String
  let op: String                          // "task.report_progress", "resource.read", …
  let featureId: String?
  let taskId: String?
  let args: [String: BridgeValue]         // small JSON-ish value enum
}
struct BridgeResponse: Codable {          // app → server
  let id: String
  let ok: Bool
  let result: BridgeValue?                // e.g. resource body, coverage json
  let error: String?
}
```

- **Concurrency:** one MCP server per worker → one socket connection → requests are naturally serial per worker; the read loop handles them in order. (No multi-client fan-in like the approval queue.)
- **Failure posture:** *fail-closed for the tool call, fail-open for the worker.* If the socket is unreachable the tool returns an MCP error (worker keeps going via files — Test 6), rather than the approval helper's auto-allow default (inappropriate for a capability bridge). Guard app-side on `isLoaded`; base writes on `freshTask(id)` (committed row) to avoid clobbering concurrent autopilot writes (e.g. `.toolchainMissing`/`.regressed`).

---

## 6. Permission posture (the §2 correction, resolved)

MCP capability tools are gated by the same permission system, so we allow **only our own surface**, in each mode:

| Worker mode | Mechanism | Change needed |
|-------------|-----------|---------------|
| **autopilot task** (`.gated`) | PreToolUse hook already fires for `mcp__atelier__*` (Test 5) | hook/queue **auto-approves the `mcp__atelier__*` prefix + `ReadMcpResourceTool`** — a small addition to the allow logic, **not** a change to the approval flow |
| **review** (`.ungated`, bypass) | already allowed | none |
| **brief chat** (`.chat`, bypass + `--disallowed-tools`) | already allowed; Test 7 shows tools work even with ToolSearch disallowed | ensure `--disallowed-tools` never lists `mcp__atelier__*`; add `--mcp-config` to this branch |

This keeps guardrail §2.1 ("capability only, never permissions") true: we never route approvals *through* MCP, and we never touch the hook/queue/worktree flow — we only widen the allow-list for our first-party tools.

---

## 7. Feature-scoping & kill-switch

- **Gate = task ownership (`task.featureId != nil`).** A spawn gets `--mcp-config` iff its task belongs to a feature — so the worker is handed *that feature's* MCP context, **regardless of which UI launched it** (feature flow, kanban relaunch, save-and-spawn). Free/project tasks (`featureId == nil`) never get MCP. This is simpler and safer than gating on launch site: the MCP surface is scoped to the owning feature, and the first-party `mcp__atelier__*` / `ReadMcpResourceTool` calls are internal capability ops (progress, own-resource reads) with nothing destructive to gate — so auto-accepting them is fine even in a human-watched, non-autopilot session. (Earlier drafts gated on "originates from FeatureFlowView"; that over-specified — a feature task manually relaunched from the kanban should still get its feature's context.)
- **Phase 1 scope:** wired in `TaskSpawner.execute` (the task-build spawn). The `iterate` and `runManagedWorker` (feature-synthesis) spawns do **not** yet get MCP — added in later phases.
- **Kill-switch:** one app-level flag (`MCPCapability.isEnabled`, UserDefaults), **OFF** through Phases 1–3, **ON** in Phase 4. No per-project toggle. When OFF, no spawn gets `--mcp-config`.

---

## 8. MCP surface → real entry points

**Resources** (read via `ReadMcpResourceTool`):
| URI | Backed by |
|-----|-----------|
| `atelier://feature/{id}/spec` | **living, agent-writable spec** = the evolving `brief.md` **plus** an appended "Build findings" section (Decision D1). Served via bridge (`Feature.briefRoomId → ChatRoom.briefFileURL`), tolerate missing/empty |
| `atelier://feature/{id}/brief` | same living `brief.md` (alias/view of the spec) |
| `atelier://feature/{id}/tasks` | `AppStore.tasks(inFeature:)` |
| `atelier://task/{id}` | `AppStore.freshTask(id)` + backlog `.md` body |
| `atelier://project/graph` | `ExecutionPlanner.waves(tasks:allTasks:)` |
| `atelier://feature/{id}/coverage` | `DossierBuilder.coverageLineRate` (dotnet) or `not_measured` |

**Tools** (all mutations route to `@MainActor AppStore`):
| Tool | Maps to |
|------|---------|
| `task.report_progress(taskId, pct, note?)` | **ephemeral** in-memory observable (Decision D2) → kanban |
| `task.update_status(taskId, status)` | `AppStore.updateTaskStatus` (rawValues: `To Do`/`In Progress`/`Review`/`Done`/`Blocked`) |
| `task.signal_blocked(taskId, reason, needs?)` | `updateTaskStatus(.blocked)` (exists) + ephemeral reason |
| `task.get_dependencies(taskId)` | `ExecutionPlanner.runnableNow` w/ `allTasks = store.tasks(in: project.id)` |
| `wave.mark_done` / `plan.next_wave` | thin wrappers over `applyGate(status:.done)` + `ExecutionPlanner`; **serial merges preserved** |
| `review.request(taskId)` | `AIAssistant.reviewWorktree(...)` |
| `brief.*` | serialize into `brief.md` (canonical) + notify preview |
| `spec.record_finding(featureId, finding, impact?, workaround?)` | **(D1)** appends a structured entry to the living spec's "Build findings" section so other feature workers/reviewers see discovered constraints & workarounds |
| `coverage.get` / `coverage.uncovered` / `test.report_run` | `DossierBuilder` (dotnet) / structured run feeding `TestDossier` |

**Prompts** (`prompts/list`+`get`): back `atelier/decompose`, `atelier/review`, `atelier/synthesize-feature` by **calling the existing `AIAssistant` statics over the socket** (they own model choice, cost accounting, and tolerant parsers — do not reimplement). `atelier/refine-brief` is the exception: it's a **multi-pass chat-session** method on `PreparePromptView` (`maxRefinePasses=4`, sentinel-driven), not a one-shot — bridges to the chat path.

---

## 9. Additive migrations (all conditional, DEBUG-erase-safe)

`eraseDatabaseOnSchemaChange` is **DEBUG-only** (`Schema.swift:18-20`); every new migration is the next ordered `registerMigration("vN_…")`.

- `v13_task_progress` — **SKIPPED** (D2: progress is ephemeral in-memory, no migration).
- `v14_task_block_reason` — only if `signal_blocked` needs a durable reason (else ephemeral).
- `v15_feature_spec_snapshot` — **NOT NEEDED** (D1: spec is the living `brief.md`, not an immutable snapshot).
- `v16_feature_coverage` — only if coverage is persisted (else read live per §D3).

**Net for Phase 1: zero migrations.** The living spec/brief is a file; progress is in-memory. Migrations, if any, arrive later and only for durable block-reason.

---

## 10. Decisions — RESOLVED

- **D1 — `atelier://feature/{id}/spec` = living, agent-writable spec.** The spec evolves; it is the `brief.md` plus an appended **"Build findings"** section. When a worker discovers something impossible (e.g. an API can't do X) and works around it, it calls `spec.record_finding(...)`, which appends a structured note so **other feature workers and reviewers become aware** of the constraint + workaround. No immutable snapshot, no `v15` migration. `brief` and `spec` are two views of the same living file.
- **D2 — `report_progress` = ephemeral in-memory `@Observable`.** No migration, no git/frontmatter churn. Progress resets on app restart (acceptable — transient build state).
- **D3 — multi-mode coverage parsers, built now.** `coverage.get` produces a real number across **swift, node, python, and dotnet** (not dotnet-only). Requires per-mode `coverageCommand` entries in `ProjectProfile` + parsers alongside `CoberturaParser` (swift → `xcrun xccov`/`llvm-cov`; node → `c8`/`nyc` lcov-or-json-summary; python → `coverage.py`/`pytest-cov` `coverage.xml`). Modes with no known tool still return `not_measured`.

---

## 11. Phasing (unchanged, walking-skeleton first)

- **P1** — `AtelierMCPServer` speaking minimal MCP + `AtelierBridgeListener` + **1 tool** (`task.report_progress` → live ephemeral kanban %) + **1 resource** (`atelier://feature/{id}/spec` = living `brief.md`). Thread `featureId`/`taskId`. Add `AtelierTests` (codec + bridge). Kill-switch OFF. E2E proof against the smoke fixture. **Zero migrations.**
- **P2** — `brief.*` tools + `spec.record_finding` (D1 write-back) + `spec`/`brief` resources + preview integration.
- **P3** — `coverage.*` (multi-mode parsers, D3), `test.report_run`, `task.*`, `wave.*`.
- **P4** — prompts, docs, CHANGELOG, flag default-on, final `/code-review high`.

Each phase: `xcodegen generate && xcodebuild … build` green, tests green, `/code-review high`, file+git fallback intact.
