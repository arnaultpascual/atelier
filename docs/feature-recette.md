# Feature — Recette (auto-generated acceptance test plan)

## Goal

When a feature reaches the end of the flow (synthesis / ready-to-merge), Atelier generates an
**interactive acceptance test plan** — a "recette" — as a self-contained HTML page: what a human
(or another dev on the PR) should run to validate the feature we just built. It's the shippable
first slice of the parked *Chantier Recette* idea (full dynamic boot+browser acceptance comes later,
with this checklist as its backbone).

Decided scope (2026-07-05):
- **Hybrid generation**: deterministic seeds from data Atelier already has, enriched by an agent
  sub-step that writes concrete steps. Graceful fallback to deterministic-only.
- **Output**: `FEATURE-<slug>-recette.html` at the project root (committable, travels with the branch;
  local file — no PR-body injection for now).
- **Trigger**: auto-generated at the end of synthesis + an "Ouvrir la recette" button in Finish.
  No forced browser open.

## The data is already there

The recette is mostly a *rendering* of what synthesis already produces:

| Source | Becomes |
|---|---|
| Brief **Acceptance Criteria** (`- [ ] …` bullets) | P0 "vérifier ce critère" items — the definition of done |
| Brief **Build Findings** (workarounds) | P1 "confirmer que ce contournement est acceptable" |
| **Coverage** report (`belowTarget`) | P1 "tester à la main les zones peu couvertes" |
| **Tasks** built | P2 "la tâche est intégrée et opérationnelle" |
| always | P0 smoke ("la feature démarre") + P1 regression ("suite verte, rien de cassé") |

## Architecture — agent produces DATA, app owns the PAGE

Mirrors `decomposeBrief`: the worker never authors HTML/CSS.

```
synthesis end
  ├─ RecetteBuilder.deterministicSeeds(brief, tasks, coverage, feature) -> [RecetteItem]   (pure)
  ├─ AIAssistant.buildRecette(brief, deliverable, diff, seeds) -> [RecetteItem]?            (hybrid; nil → seeds)
  ├─ RecetteBuilder.renderHTML(items, feature, project) -> String                          (vetted template)
  └─ write FEATURE-<slug>-recette.html at project root
```

`RecetteItem` (Codable — this is the agent's JSON schema too):

```
{ id, group, title, priority (p0|p1|p2), validates, steps: [String], expected, hint? }
```

The HTML template is the vetted one (checkboxes, priority chips, progress bar, `localStorage`,
"P0 only" filter). The app injects the items as cards grouped by `group`, sorted by priority.
All text is HTML-escaped (titles/steps come from the brief + the agent).

## Increments

1. **Core (pure, testable now)** — `RecetteItem`, deterministic seeds, HTML render, write. Unit tests.
2. **Agent enrichment** — `AIAssistant.buildRecette` (structured JSON) + fallback to seeds.
3. **Wiring** — generate at synthesis end; "Ouvrir la recette" button in Finish (path derived from
   slug, no DB column). Toast/note.

## Validation

Building this forces a **real E2E run with a test app** — which is also the live smoke the whole
feature-flow (MCP layer included) still needs. So the recette's E2E doubles as the branch's E2E.
Later evolution: an agent *executes* checkable items and pre-checks what it verified (the dynamic
Chantier Recette).
