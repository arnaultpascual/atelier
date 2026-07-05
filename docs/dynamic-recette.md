# Dynamic recette — boot smoke

## Goal

After a feature builds, actually **launch the app and confirm it doesn't crash** — the class of
failure the unit-test gate structurally can't see (missing manifest permission, broken DI, a
startup NPE, a dev server that won't boot). The canonical case: an Android networking feature that
compiles + passes unit tests but dies at runtime with `SecurityException` (missing INTERNET
permission). Only running it catches that.

This is the first, highest-ROI rung of the parked *Chantier Recette* (dynamic acceptance): a
**boot smoke** — launch, watch for a crash in the first N seconds, done. The fuller "drive the
journeys + screenshots" rung comes later; this one is deliberately shallow and reliable.

Decided scope (2026-07-05): **boot smoke**, **all three platform families** (Android / web / node),
result feeds the recette + deliverable.

## Non-negotiable principle

**Opt-in + advisory. Never a hard merge gate.**
- Atelier's gate stays build-independent (unit tests). The boot smoke *informs* the recette
  ("App launches without crashing" → pass/fail + the crash log) and the deliverable — it does not
  block the merge. Emulators/dev-servers are slow and flaky; a flaky hard gate is a non-starter.
- Enabled per project (like `buildVerifyFinal`): `bootSmokeEnabled`, default OFF.

## Mostly deterministic, not agent-driven

A boot smoke = run known launch commands + scan the log for a crash. That's **deterministic** —
more reliable and cheaper than an agent. (The agent is only needed for the *drive* rung — navigate
+ read screenshots — which is out of scope here.) A per-mode **boot recipe** encodes the commands;
the launch target is inferred with sane defaults + an optional per-project override.

`BootSmokeResult { platform, launched: Bool, crashLog: String?, note: String }` — advisory.

### Per-mode boot recipes

| Mode | Boot | Crash signal | Notes |
|---|---|---|---|
| **android** | ensure an emulator is up (`adb devices`; else skip w/ note), `./gradlew installDebug`, `adb shell monkey -p <pkg> -c android.intent.category.LAUNCHER 1`, tail `adb logcat` ~10s | `FATAL EXCEPTION` / process death / ANR for `<pkg>` | `<pkg>` from `applicationId`; needs a running AVD (probe like `adb`). No emulator → skip, not fail. |
| **web** (react-vite / next / other-frontend) | `npm run dev` (or build+serve), wait for the port, headless GET `/` | non-2xx, dev-server exits, or a console/page error | port from vite/next config or output; default 5173/3000. |
| **node** (node-backend) | `npm start` / boot, wait for the port, `curl` the health/root route | server exits or route unreachable | port/route inferred from the app or the brief; override in project settings. |

All run on the **integration branch** at the project root, post-build, with a bounded timeout +
one retry (flaky-boot tolerance). Graceful skip (with a note) when the platform prerequisite is
absent (no emulator, no dev script) — a skip is never a failure.

## Wiring

```
Finish / synthesis (if bootSmokeEnabled)
  └─ BootSmokeRunner.run(mode, projectPath, integrationBranch) -> BootSmokeResult
       ├─ recipe(mode).launch + logscan (deterministic, TestRunner.runCommand env)
       └─ result → (a) the recette's "App launches" item is pre-checked pass/fail (+ crashLog),
                    (b) a line in the deliverable's "Quality & coverage" section.
```

- Reuses `TestRunner.runCommand` (toolchain env: ANDROID_HOME, PATH) — same plumbing the gate uses.
- The crash log on failure lands in the deliverable + the recette item (like the post-merge
  regression report), so the human sees *why* it didn't boot without re-running anything.

## Increment plan

1. `BootSmokeResult` + `BootSmokeRunner` + a per-mode `bootRecipe` on `ProjectProfile.BuildConfig`
   (nil = mode can't boot-smoke). Deterministic launch + logscan. Unit-test the log-scan + recipe
   selection (pure); the launch itself is integration.
2. `project.bootSmokeEnabled` (additive migration) + a Finish-stage toggle (like build-verify) +
   inferred-target override field.
3. Wire into synthesis → feed the recette item + deliverable line.

## Boundaries / risks

- Android needs a running emulator; detect + skip gracefully (don't fail the recette on "no AVD").
- Advisory only — a red boot smoke annotates the recette; the human decides. Never blocks merge.
- Port/target inference is best-effort with an override; a wrong guess = a skip + a note, not a
  false failure.
- Own branch, after the current MCP branch merges — this is a feature, not a patch.
- Evolution: once the boot smoke is solid, the *drive* rung (agent boots + navigates the recette's
  acceptance criteria + screenshots) layers on top, reusing the same launch recipes.
