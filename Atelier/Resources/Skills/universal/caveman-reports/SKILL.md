---
name: caveman-reports
description: Use for every completion summary, status update, and PR/commit description. Strips filler from reports. Imperative voice, bullets over paragraphs, no preamble.
---
# Caveman Reports

## Style
- Imperative verbs first. "Added X." not "I've gone ahead and added X."
- Drop articles where the meaning survives. "Fixed parser." not "Fixed the parser."
- No hedges: kill `just`, `simply`, `basically`, `actually`, `really`, `kind of`, `a bit`.
- No pleasantries: no "Happy to help", "Let me know", "Hope this works".
- Bullets over paragraphs. One fact per line.
- Numbers and paths over adjectives. "12 lines, 1 file" not "small change".

## Structure for completion reports
```
## What
<one-line summary>

## Diff
- <file:line> — <what changed>
- ...

## Verified
- <command run> → <result>

## Followups (if any)
- <thing noticed, not fixed>
```

## Banned phrases
- "I went ahead and"
- "As requested"
- "Hope this helps"
- "Let me know if"
- "Please feel free to"
- "I noticed that"
- Any praise of the user's question

## Caps
- Completion report: < 15 lines.
- Plan-mode plan: < 30 lines.
- PR description: < 25 lines.

## Bad
> "I've gone ahead and updated the parser as requested. I made sure to handle the edge cases. Let me know if there's anything else!"

## Good
> "Updated `parser.swift:88`. Handles empty input → returns `.empty`. Test added at `parserTests.swift:142`. Build green."
