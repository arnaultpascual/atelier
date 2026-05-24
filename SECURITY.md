# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through GitHub's
[**"Report a vulnerability"**](https://github.com/arnaultpascual/atelier/security/advisories/new)
flow (Security → Advisories). Include what you found, how to reproduce it, and the impact you
expect. You'll get an acknowledgement and, once a fix ships, credit if you'd like it.

## Supported versions

Atelier is an actively developed solo project. Security fixes target the latest `1.0.x` release
and `main`. Older builds are not maintained.

## Security model — what you should know before running Atelier

Atelier orchestrates [Claude Code](https://docs.claude.com/en/docs/claude-code) agents that
**execute real tools** on your machine — reading and writing files, running shell commands, and
making network requests — on your behalf. Treat spawning an agent with the same caution you'd
apply to running `claude` yourself in that repository. A few specifics:

### Distribution & runtime model

Atelier runs **outside the macOS App Sandbox** by necessity. It orchestrates the `claude` and
`git` binaries against the real repositories you point it at — creating worktrees, running
tools, reading your git and Claude config — none of which a sandbox would permit. (A sandboxed
process confines its child processes to the same container, so a sandboxed `claude` couldn't
touch your repos at all, which would defeat the entire tool.) Atelier therefore runs with your
normal user privileges; **don't point it at repositories or briefs you don't trust.**

To keep distribution trustworthy despite not being sandboxed, official release builds are:

- **signed with a Developer ID Application certificate**,
- built with the **Hardened Runtime** enabled, and
- **notarized by Apple** and stapled, so Gatekeeper verifies them on first launch with no
  security warning.

If you build from source yourself, you're running an unsigned local build — which is expected,
and identical in capability.

### Human-in-the-loop is the primary control

Every tool call a task worker makes is intercepted by a `PreToolUse` hook and surfaced in the
**Approvals** inbox before it runs (see [ARCHITECTURE.md](ARCHITECTURE.md#approvals-the-pretooluse-hook)).
Two things follow from this:

- **Learned/auto-approve rules trade safety for convenience.** When you teach a per-project rule
  to auto-approve a tool/pattern, future matching calls run without prompting. Scope these
  narrowly.
- **The approval helper fails open by default.** If the helper can't reach Atelier's socket, it
  **allows** the call rather than blocking it (an availability choice). The binary supports a
  `--deny-on-failure` flag to invert this for stricter setups.

### Worktree isolation, manual merge

Agents work in dedicated git worktrees on their own branches (`worktree-<taskId>`), and the
spawn prompt instructs them not to `merge`, `push`, or `rebase`. **You** review the diff and
merge by hand. Atelier never writes to your default branch. Note this is a guardrail, not a
hard sandbox — a tool call you approve can still do whatever you allowed it to.

### Secrets handling

- An Anthropic API key you enter is stored in the **macOS Keychain** and injected into the
  worker subprocess as `ANTHROPIC_API_KEY`. Atelier doesn't transmit it anywhere itself.
- If you use a Claude subscription instead, Atelier passes **no** key — `claude` uses its own
  stored OAuth credentials.
- The **Usage → subscription limits** panel reads Claude Code's OAuth token from the Keychain
  **read-only** and only after you opt in. The token is never written, refreshed, or sent
  anywhere except Anthropic's own usage endpoint.
- Temporary per-spawn settings files (in the system temp directory) contain the approval-hook
  command line, not secrets, and are deleted when the run ends.

### Data locality

All Atelier state is local: a SQLite database at
`~/Library/Application Support/Atelier/atelier.sqlite`, task Markdown inside your repositories,
and per-spawn scratch/worktree directories. There is no Atelier server and no telemetry.

## Out of scope

This policy covers Atelier itself. Vulnerabilities in the `claude` CLI, the Anthropic API, the
underlying models, or third-party Swift dependencies should be reported to their respective
maintainers (though we're happy to help coordinate if you're unsure where something belongs).
