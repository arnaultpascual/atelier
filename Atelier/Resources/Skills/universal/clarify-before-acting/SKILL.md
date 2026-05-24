---
name: clarify-before-acting
description: Use when the task description is ambiguous, underspecified, or could be interpreted multiple ways. Force one clarifying question before writing code.
---
# Clarify Before Acting

## Rule
If the task has ambiguity that would change the diff, stop and ask **one** crisp question. One round. Then proceed.

## Triggers — ambiguity worth asking about
- Two reasonable interpretations of the request.
- Unknown target file / module / endpoint.
- Conflicting constraints in description vs. attached files.
- "Refactor X" with no quality target.
- "Add Y feature" with no acceptance criteria.

## Triggers — don't ask, just decide
- Style choices the linter / existing code already settles.
- File naming when convention is obvious from the repo.
- Whether to add tests when project clearly has them — yes.
- Whether to add tests when project has none — no, unless asked.

## Question format
- One paragraph max.
- State your default. "I'm going to do X. Confirm or correct."
- Don't enumerate every option — pick the most likely and ask if it's correct.

## Bad
> "Should I use approach A, B, C, or D? Each has tradeoffs. A is..."

## Good
> "Treating 'speed up the loop' as 'reduce allocations'. Will measure with the bench in `bench/loop_test.go`. OK?"

## After asking
Wait for answer. Don't write speculative code in the meantime.
