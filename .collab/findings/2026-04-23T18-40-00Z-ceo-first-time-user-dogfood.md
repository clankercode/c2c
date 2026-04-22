# First-Time-User Dogfood: c2c CLI Sweep

**Date:** 2026-04-23
**Author:** CEO
**Status:** COMPLETE

## Method

Ran the following commands as a first-time user would (fresh env, no context):
- `c2c --help`, `c2c start --help`, `c2c install --help`, `c2c list`, `c2c whoami`, `c2c doctor`, `c2c relay --help`, `c2c roles --help`
- Plus: `c2c init --help`, `c2c rooms --help`, `c2c status`, `c2c verify`, `c2c send --help`, `c2c config --help`, `c2c`, `c2c instances`
- Reviewed output of each for: missing examples, confusing flag names, unhelpful errors, silent failures, surprising behavior

---

## BLOCKERS (first-time user cannot proceed)

### B1: `c2c whoami` / `c2c list` — "error: no session ID" is not actionable

```
$ c2c whoami
error: no session ID. Set C2C_MCP_SESSION_ID.
```

**Problem:** The error tells you _what_ is missing but not _how_ to fix it. A first-time user has no idea what C2C_MCP_SESSION_ID is, where to get one, or whether they need to run a different command first.

**Fix:** The error should be actionable:
```
error: no session ID. Set C2C_MCP_SESSION_ID, or run 'c2c init' to register this session.
hint: 'c2c init --help' to get started
```

---

### B2: `c2c --help` — no Getting Started path for new users

The top-level help shows 50+ commands organized in TIER 1/2/3/4 with no explanation of what tiers mean or where a new user should start. The only way to discover `c2c init` (the onboarding command) is to already know it exists.

**Fix:** Add a "GETTING STARTED" or "QUICK START" section at the top of `c2c --help`:
```
GETTING STARTED
     c2c init           One-command setup — configure, register, join swarm-lounge
     c2c start CLIENT   Launch a managed client session
     c2c help COMMAND  Get help for a specific command
```

---

### B3: `c2c` (no args) — pty-inject cap warning uses hardcoded linuxbrew path

```
pty-inject: MISSING cap_sys_ptrace — kimi/codex/opencode PTY wake will fail
fix: sudo setcap cap_sys_ptrace=ep /home/linuxbrew/.linuxbrew/bin/python3
```

**Problem:** The sudo command hardcodes `/home/linuxbrew/.linuxbrew/bin/python3`. This is Max's setup. A first-time user on a different system (system python, pyenv, conda, etc.) gets a command that won't work for them.

**Fix:** Detect the actual python3 in use (the same one c2c is invoked with), or say:
```
fix: sudo setcap cap_sys_ptrace=ep $(which python3)
```

---

### B4: `c2c start --help` — CLIENT argument has no guidance

```
ARGUMENTS
     CLIENT (required)
         Client to start (claude, codex, codex-headless, kimi, opencode, crush).
```

**Problem:** Six client names, no description of what each is or when to use it. "codex-headless" vs "codex" is especially confusing.

**Fix:** Add a quick description table:
```
ARGUMENTS
     CLIENT (required)
         Client to start:
           claude         Claude Code (full IDE integration)
           codex          Codex (web-based, headless-capable)
           codex-headless Codex running without GUI
           opencode       OpenCode (local file browsing)
           kimi           Kimi (Chinese-language model, --wire mode)
           crush          Crush (experimental)
```

---

## ANNOYANCES (confusing but not blocking)

### A1: `c2c list` — `???` status is unexplained

```
kimi-wire-ocaml-smoke2 ???
kimi-wire-ocaml-smoke  ???
```

**Problem:** Some sessions show `???` instead of `alive`/`dead`. A first-time user doesn't know if this means "unknown" or "in progress" or broken.

**Fix:** Show `(unknown client_type)` or `(unconfirmed)` to clarify these are sessions with no heartbeat reporting client type.

---

### A2: `c2c rooms --help` — `visibility` subcommand doesn't document valid values

```
visibility     Get or set room visibility.
```

**Problem:** No mention of what values are valid (public/invite_only). User must guess or try `--help` on the subcommand.

**Fix:** `visibility [--set public|invite_only]  Get or set room visibility.`

---

### A3: `c2c install --help` — TUI has no preview/dry-run

```
With no subcommand, c2c install runs an interactive TUI...
```

**Problem:** A first-time user can't see what the TUI would do without running it. They might accidentally configure something they didn't intend.

**Fix:** Add `c2c install --dry-run` or `c2c install --preview` that shows what would be configured without making changes.

---

### A4: `c2c roles --help` — no EXAMPLES section; `--agent` is mysterious

```
-a NAME, --agent NAME
    Start from canonical role at .c2c/roles/<NAME>.md
```

**Problem:** What is a "canonical role"? What format is the .md file? How does a new user create one? The `c2c roles` command exists but `--help` gives no guidance.

**Fix:** Add EXAMPLES section:
```
EXAMPLES
     c2c roles validate          Check role files for completeness
     c2c roles compile --client opencode my-role   Compile a role for a client
     # See .c2c/roles/*.md for existing role examples
```

---

### A5: `c2c relay --help` — `serve` vs `connect` vs `setup` is unclear

```
serve        Start the relay server.
connect      Run the relay connector.
setup        Configure relay connection.
```

**Problem:** A new user doesn't know whether they need to "serve" a relay (they probably don't), "connect" to an existing one, or "setup" something first. These are described but not contextualized.

**Fix:** Add an introductory sentence:
```
The relay connects brokers across machines. Use 'setup' to configure your connection,
'connect' to start the connector, or 'serve' to run a relay server (operators only).
```

---

### A6: `c2c --help` — TIER system unexplained

```
== TIER 1: SAFE (agents can use freely) ==
== TIER 2: LIFECYCLE AND SETUP (safe with care) ==
== TIER 3: SYSTEM (do NOT run from inside an agent) ==
```

**Problem:** The tier concept is clever but opaque. A first-time user sees "TIER 3" and might think it's the most important or most reliable tier. "do NOT run from inside an agent" is a critical warning but buried in a tier system the user doesn't understand.

**Fix:** Add a legend at the top of the COMMANDS section:
```
COMMAND TIERS
     Tier 1 (SAFE):         Routine commands any agent can use freely
     Tier 2 (LIFECYCLE):    Session management — use with care
     Tier 3 (SYSTEM):        Infrastructure — do NOT run inside an agent session
     Tier 4 (INTERNAL):      Plumbing — never shown in agent help
```

---

### A7: `c2c doctor` — "stale deploy" verdict inconsistency

```
⚠ relay: reachable — 0.8.0 @ 10c59cd prod mode ⚠ stale deploy (deployed: 10c59cd, local: 3736ff5) (1 commits)

=== Verdict ===
  ✓ No push needed
```

**Problem:** The relay section says "stale deploy" and shows "1 commits" but the verdict says "No push needed". This is contradictory — if there's a stale deploy, why is no push needed?

**Fix:** Either (a) change verdict to "PUSH RECOMMENDED" when there are relay-critical commits, or (b) clarify that local-only commits don't trigger the push recommendation. The current output conflates "stale relay deploy" with "local unpushed commits" in a confusing way.

---

### A8: `c2c` (no args) — "Clients" section uses "configured" without defining it

```
Clients
  claude     on PATH, not configured
  codex      configured
```

**Problem:** What does "configured" mean? Does it mean MCP is set up? Does it mean the binary is installed? A first-time user sees "not configured" and doesn't know what to do about it (except `c2c install claude` but that's not mentioned).

**Fix:** Add a hint:
```
Clients
  claude     on PATH, not configured  → run 'c2c install claude' to set up
  codex      configured  → ready to use
```

---

## POLISH (minor, nice-to-have)

### P1: Exit codes 123/124/125 not explained

Every `--help` output shows:
```
EXIT STATUS
     123  on indiscriminate errors reported on standard error.
     124  on command line parsing errors.
     125  on unexpected internal errors (bugs).
```

**Problem:** "indiscriminate errors" is unclear. What does 123 mean in practice? When would a user see it?

**Fix:** "123 = operational error (e.g., relay unreachable); 124 = you passed a bad flag; 125 = bug in c2c"

---

### P2: `c2c config --help` — `generation-client` description is vague

```
generation-client [CLIENT]
    Show or set the generation_client preference (claude|opencode|codex).
```

**Problem:** What does "generation_client" control? Why would I set it?

**Fix:** "generation_client: which client handles code generation when multiple are available (e.g., in multi-agent workflows)"

---

### P3: `c2c install self --help` — `--mcp-server` flag unexplained

```
--mcp-server    Also install the c2c MCP server binary
```

**Problem:** What is an MCP server? Why would I want it? Most users won't know.

**Fix:** "--mcp-server: also install the JSON-RPC server that lets coding CLIs (Claude Code, Codex, etc.) exchange messages via c2c"

---

### P4: `c2c send --help` — `--from` flag uses "override sender alias" but doesn't explain why

```
-F ALIAS, --from ALIAS
    Override sender alias. Useful for operators/tests running outside an agent session.
```

**Problem:** "override sender alias" — but what does alias mean in this context? The user might think they can fake being someone else (security concern) when actually it's just a display name.

**Fix:** "--from ALIAS: send messages as this alias (must be registered; use `c2c register --alias ALIAS` first)"

---

## Summary

| # | Severity | Issue |
|---|----------|-------|
| B1 | BLOCKER | `c2c whoami` "no session ID" error is not actionable |
| B2 | BLOCKER | `c2c --help` has no Getting Started path |
| B3 | BLOCKER | `c2c` pty-inject warning uses hardcoded linuxbrew path |
| B4 | BLOCKER | `c2c start` CLIENT argument has no guidance |
| A1 | ANNOYANCE | `c2c list` shows `???` with no explanation |
| A2 | ANNOYANCE | `c2c rooms visibility` doesn't document valid values |
| A3 | ANNOYANCE | `c2c install` TUI has no preview/dry-run |
| A4 | ANNOYANCE | `c2c roles --agent` is unexplained |
| A5 | ANNOYANCE | `c2c relay` serve/connect/setup not contextualized |
| A6 | ANNOYANCE | TIER system in `--help` is unexplained |
| A7 | ANNOYANCE | `c2c doctor` "stale deploy" verdict is self-contradictory |
| A8 | ANNOYANCE | `c2c` (no args) "configured" status unexplained |
| P1 | POLISH | Exit codes 123/124/125 unexplained |
| P2 | POLISH | `generation-client` purpose vague |
| P3 | POLISH | `--mcp-server` flag unexplained |
| P4 | POLISH | `--from` alias could be misread as impersonation |

**Recommended priority for polish pass:** B1 > B2 > B3 > B4 > A6 > A7 > A1 > A5 > A3 > A4 > A2 > P1 > P2 > P3 > P4

(End of file — 15 pain points)