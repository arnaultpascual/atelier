---
name: surgical-changes
description: Use when modifying existing code. Constrains scope to user's request. Prevents incidental refactors and "while I'm here" cleanup that bloats diffs.
---
# Surgical Changes

## Scope
Only change what user requested. Skip cleanup, renames, "while I'm here" fixes, formatting passes.

## Rules
- Edit minimum lines needed for the requested behavior.
- Keep existing patterns even when suboptimal. Don't switch styles mid-file.
- No new imports user didn't ask for.
- No new files unless task requires one.
- No dependency bumps.
- No reformatting of untouched code.

## When tempted to "improve"
1. Note the improvement at the bottom of your report under `## Followups`.
2. Don't apply it.
3. Continue the task.

## Stop conditions — ask user before continuing
- Diff > 30 lines outside the requested area.
- Need to touch files unrelated to the immediate problem.
- Discover a real bug while doing the requested change — flag it, don't silently fix it.

## Anti-pattern
> "I also reformatted the imports and renamed `foo` to `bar` for consistency."

## Good
> Diff minimal. Touched files listed. One thing changed. Cleanup ideas under `## Followups`.
