# Contributing to Atelier

Thanks for your interest! Atelier is a native macOS app, so the contribution loop is "open in
Xcode, build, run". This guide covers the setup, the conventions, and the two most common
extension points.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 16+ with the Swift 6 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) on your `$PATH`, authenticated
  (subscription or API key) — you need it to actually run agents

## Build & run

```bash
git clone https://github.com/arnaultpascual/atelier.git
cd atelier
xcodegen generate     # regenerates Atelier.xcodeproj from project.yml
open Atelier.xcodeproj
```

Build & run with **⌘R**. Or from the command line:

```bash
xcodebuild -project Atelier.xcodeproj -scheme Atelier \
           -configuration Debug -destination 'platform=macOS' build
```

**The Xcode project is generated, not committed.** `Atelier.xcodeproj/` is gitignored. Whenever
you add, remove, or move a source file, run `xcodegen generate` again so the project picks it
up. Source layout and build settings live in [`project.yml`](project.yml).

## Project layout

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full picture. In short, `Atelier/` is grouped by
feature:

```
Atelier/
  Storage/            GRDB models, Schema, the reactive AppStore, GitService
  Worker/ Subprocess/ TaskSpawner, WorkerRunner, ClaudeLocator
  Approvals/ MCP/     the PreToolUse-hook approval flow
  Profiles/           stack detection + SkillBundler
  Resources/Skills/   bundled SKILL.md files (universal/ + profiles/<id>/)
  NDJSON/ Models/     stream parsing → StreamEvent → AgentState
  Backlog/ Chat/ Usage/ Detail/ Settings/ Sidebar/   feature panes
  DesignSystem.swift  colors, fonts, corner radii (the "atelier" palette)
AtelierApprovalHelper/   the stdio approval-hook binary (separate target)
```

## Conventions

- **License header.** Every Swift file starts with `// SPDX-License-Identifier: MIT`.
- **Concurrency.** UI and state types are `@MainActor` and use `@Observable` (the Observation
  framework, not Combine/`ObservableObject`). Push blocking work to the edges: IO lives in
  `actor`s (`WorkerRunner`) or `async` DB calls. The target builds under Swift 6 with
  `SWIFT_STRICT_CONCURRENCY: minimal` — don't introduce data races to get something to compile.
- **Database.** Column names are camelCase to match Swift properties and GRDB's `belongsTo`
  generator. Schema changes go in `Schema.swift` as a **new** migration — never edit a shipped
  one. (`DEBUG` builds erase-on-change, so test a fresh migration in Release too.)
- **Tasks on disk.** Task content is owned by `<repo>/backlog/tasks/*.md`, not the DB. If you
  touch task persistence, preserve `BacklogMD`'s round-tripping of unknown frontmatter keys.
- **Design system.** Use the `Color.atelier*` / `AtelierFont` / `AtelierCorner` tokens from
  `DesignSystem.swift` rather than hard-coded colors and font sizes.
- **No new dependencies without a reason.** The stack is deliberately small (subprocess, GRDB,
  Yams). We removed unused packages for 1.0 — please don't re-add weight casually.

## Commit & PR style

Commit messages follow the existing log: a short, imperative summary, often with an area prefix.

```
Kanban: execution rounds in To Do + batch spawn
Chat: fix session path encoding + Claude-style composer
Usage: per-message cost attribution, opt-in limits, compact heatmap
```

For pull requests: describe what changed and why, and confirm the app **builds and runs** (and,
for UI changes, that you exercised the feature). There's no CI yet, so this is on the honor
system.

## Common extension points

### Add a project profile

Profiles map a detected stack to a default model and a set of skills.

1. Add a case/entry in `Atelier/Profiles/ProjectProfile.swift` (id, display name, default model).
2. Teach `ProjectProfileDetector.detect(at:)` how to recognize it (which marker files), keeping
   the most-specific checks first.
3. Create `Atelier/Resources/Skills/profiles/<your-id>/<skill-name>/SKILL.md` for any
   stack-specific guidance.
4. `xcodegen generate`, build, and confirm the profile shows up in the **Skills** tab and is
   detected on a sample repo.

### Add a skill

A skill is a single `SKILL.md` file injected into each worker's `.claude/skills/`.

- **Universal** (applies to every project): `Resources/Skills/universal/<name>/SKILL.md`.
- **Profile-specific**: `Resources/Skills/profiles/<profile-id>/<name>/SKILL.md`.

Format:

```markdown
---
name: surgical-changes
description: One-line trigger / summary shown in the Skills tab.
---
# Title

Guidance the agent should follow. Keep it concrete and short.
```

Because `Resources/Skills` is bundled as a folder reference, new files are picked up on the next
build — no code change needed.

## Tests

There is no automated test suite yet, and adding one is the single most valuable contribution
right now. The pure pieces (`NDJSONLineDecoder`, `BacklogMD`, `ModelRouter`,
`ProjectProfileDetector`, `GitService` parsing helpers) are good first targets. If you add a test
target, wire it through `project.yml` so `xcodegen generate` reproduces it.

## Reporting bugs & ideas

Open an issue with what you did, what you expected, and what happened. For anything
security-related, follow [SECURITY.md](SECURITY.md) instead of filing a public issue.
