---
name: tests-first
description: Use on any task that changes behavior. This project enforces strict TDD — write the failing test before the implementation, and the orchestrator runs the test command and blocks review/merge on a non-zero exit.
---
# Tests First (strict TDD)

## The loop
1. **Red** — write the test that specifies the desired behavior. Run it. See it fail for the *right* reason (assertion, not a compile error or typo).
2. **Green** — write the minimum implementation that makes it pass.
3. **Refactor** — clean up with the test still green.

Write the test BEFORE the implementation, not after. A test written after the code tends to assert what the code happens to do, not what it should do.

## The gate (why this matters here)
After you finish, **Atelier runs the mode's test command in your worktree and reads the exit code.** A non-zero exit means the task **cannot enter Review and cannot be merged** — you'll be handed the failure and asked to fix it. Your own "it works" is not the gate; the process exit is.

So before you report done, run the test command yourself and quote the result.

## Tests are living, but the gate watches for weakening
Writing the test first does NOT freeze it. If implementation reveals the planned design was wrong, fix the design AND the test together — the test must assert the **new** contract at equal-or-greater strength.
- **Legitimate** (allowed — must be declared): renaming/replacing a test because the API changed; tightening an assertion; splitting one test into sharper ones; deleting a test for behavior the corrected design no longer has.
- **Weakening** (forbidden — auto-detected, blocks merge): deleting/`@Ignore`/`skip` a test that fails because the *code* is wrong; turning `assertEquals(expected, actual)` into `assertTrue(true)`; widening an assertion to swallow the bug; dropping the only test that covered the change.
- **Declare every test edit.** When you change any test, write `.atelier/test-changes/<task-id>.md` — per change: the test, what changed, and *why the design changed*. Atelier diffs your test files; a shrunk suite with no declaration is treated as weakening.

## Rules
- **Cover the change, not the world** — test the behavior this task adds or fixes, plus the obvious edge cases. Don't backfill unrelated tests.
- **Deterministic only** — no real network, no wall-clock/sleep dependence, no random seeds left unfixed. A flaky test blocks the gate just like a real failure.
- If the repo has **no test setup yet**, scaffold the minimal one (see the mode-specific skill for where tests live and which framework) rather than skipping tests.

## Report
```
## Verified
- <test command> → exit 0, N passed / 0 failed
- new test `<name>` exercises <the behavior this task added>
```
If you genuinely cannot test something (e.g. real-device-only), say so explicitly and explain why — don't claim done.
