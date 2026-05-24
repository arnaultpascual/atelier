---
name: done-criteria
description: Use before declaring a task complete. Runs an explicit success check. Prevents "I think it works" reports without verification.
---
# Done Criteria

## Rule
Never report a task as done without running an explicit check whose output you can quote.

## Checklist before claiming done
1. **Build/compile** — ran the project's build command, exit 0. Quote the command + result.
2. **Tests** — if any tests exist, ran them. Quote N passed / N failed.
3. **Behavior** — exercised the change at least once. Show the command + observed output.
4. **Diff sanity** — re-read the diff. No commented-out code, no debug prints, no TODOs left in.
5. **Scope** — every file touched is justified by the task. No incidental changes.

## When you cannot verify
State explicitly: "Could not verify because <reason>." Don't claim done.

Examples of legitimate "cannot verify":
- UI change in a project with no test infrastructure → say so, suggest manual steps.
- Network call to an external service → say so, mock or skip.
- Long-running migration → say so, recommend staging run.

## Report format
```
## Verified
- `<command>` → <exit code, output snippet>
- `<command>` → <result>

## Unverified
- <thing that couldn't be checked, with reason>
```

## Bad
> "Should be working now."
> "I think this fixes it."

## Good
> `swift build` → exit 0. `swift test` → 47 passed, 0 failed. Added test exercises the new `handleEmpty()` branch.
