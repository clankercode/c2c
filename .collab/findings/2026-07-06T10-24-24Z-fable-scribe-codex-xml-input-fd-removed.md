# codex >=0.142: `--xml-input-fd` removed upstream — managed xml_fd deliver mode is dead; hooks are the replacement

- **When:** 2026-07-06
- **Who:** fable-scribe (codex-hooks slice, task #5)
- **Severity:** high (managed codex delivery path silently degraded)
- **Status:** replacement shipped for vanilla codex (hooks); managed-path port is a follow-up

## Symptom

`c2c start codex` deliver mode reports `unavailable`; inbound messages to
managed codex sessions no longer inject via the xml_fd path. The
CLAUDE.md "Two codex binaries" note said to point `[default_binary] codex`
at `/home/xertrov/.local/bin/codex` (v0.125.0-alpha.2) — that binary no
longer exists.

## Discovery

- The machine now has a single codex binary: `/home/xertrov/.bun/bin/codex`,
  npm `@openai/codex`, **v0.142.5**.
- `--xml-input-fd` was an alpha-only flag and was **removed upstream** — no
  current codex build advertises it. The capability probe
  `codex_supports_xml_input_fd` (`ocaml/c2c_start.ml`) now always returns
  false, so `Codex_xml_fd` capability never registers and the managed
  deliver-watch forwards nowhere.
- `.c2c/config.toml` `[default_binary] codex` pointed at the deleted alpha
  binary; any `c2c start codex` honoring it would fail to exec.
- Meanwhile codex v0.142 shipped **Claude-Code-style hooks** (stable,
  enabled: `codex features list` → `hooks stable true`): 10 events incl.
  SessionStart/UserPromptSubmit/PreToolUse/PostToolUse/Stop, JSON payload on
  stdin, `hookSpecificOutput.additionalContext` injection on stdout, config
  in `~/.codex/config.toml`, one-time trust approval bypassable via
  `[hooks.state]` `trusted_hash` entries.

## Root cause

Upstream removed the experimental `--xml-input-fd` surface that c2c's
managed codex delivery was built on. Not a c2c regression; a dependency on
an alpha flag that never stabilized.

## Fix status

Shipped in this slice (branch `slice/codex-hooks`):

- `c2c hook codex` — one hook command for all codex events: resolves session
  identity (payload session_id → managed thread mapping → env/statefile →
  installer alias hint), auto-registers vanilla sessions on first fire with
  an onboarding note, drains the inbox (deferrable held until turn
  boundaries), emits `additionalContext`. Never fails the codex turn.
- `c2c install codex` — writes UserPromptSubmit/PostToolUse/SessionStart
  hooks + precomputed `[hooks.state]` trust hashes (codex's hash scheme
  reproduced and pinned by tests against live codex-written values) +
  a c2c section in `~/.codex/AGENTS.md`.
- CLAUDE.md "Two codex binaries" bullet replaced; stale
  `[default_binary] codex` entry removed from `.c2c/config.toml`.

## Follow-ups

1. **Port managed `c2c start codex` delivery to hooks**: drop the xml_fd
   deliver-watch supervisor for codex; managed sessions already export
   `C2C_MCP_SESSION_ID`, which `c2c hook codex` resolves (step 3), so the
   hook path works for them today — the remaining work is removing the dead
   xml_fd plumbing (`codex_supports_xml_input_fd`, deliver-watch scripts for
   codex, `C2C_DELIVER_XML_FD`) and making `c2c start codex` rely on hooks.
2. **Positional trust keys**: codex hook trust state is keyed by
   `<path>:<event>:<group-index>:<handler-index>`. A user inserting their own
   `[[hooks.<Event>]]` group above the c2c block re-indexes ours and breaks
   pre-trust until `c2c install codex` is re-run. Upstream has a TODO for
   durable hook ids; revisit when that lands.
3. **Alias churn for enviro-less vanilla codex**: each new codex
   conversation has a fresh session_id; without an installer alias hint the
   hook generates a new alias per conversation. Consider a per-operator
   sticky alias file.
