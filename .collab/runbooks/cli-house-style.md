# c2c CLI House Style

Conventions for `c2c <subcommand>` design. Surfaced from real
dogfood-UX hits during the 2026-04-28 burn. Each pattern names a
problem, the convention that fixes it, and 1-2 examples.

These are house-style — load-bearing, but not load-mandatory. If a
specific subcommand has a strong reason to deviate, document it inline
with the deviation.

## Pattern 1: default actionable / `--all` for archive

**Problem.** Listing commands accumulate dead/zombie entries over time
(test aliases, sweep-orphaned registrations, ephemeral one-shot peers).
Without filtering, the operationally-useful "what's running right now"
signal disappears beneath archive noise. Concrete hit: `c2c instances`
showed 377 zombie `codex-reset-*` entries against ~5 live peers
(2026-04-28, dogfood UX audit, #351).

**Convention.** A listing command's default output is the *currently
actionable* set (alive sessions, open issues, current peers). The full
historical/archived set is gated behind `--all`.

- Default = `--alive`-equivalent, no flag needed
- `--all` = include archived/zombie/closed/historical entries
- Help text on `--all` should say what gets added (e.g., "include
  unreachable registrations and historical aliases")

**Examples.**
- `c2c instances` → currently-running managed sessions only
- `c2c instances --all` → include historical and zombie entries
- `c2c list` → live aliases (registered + reachable)
- `c2c list --all` → include `??? unknown client_type` rows
- (future) `c2c findings` → open-actionable only; `--all` for the
  whole archive

**Counter-example deliberately not affected.** `c2c history` is intrinsically
an archive surface — its "default actionable" is the recent window
(default `--last 50` or similar), not "alive vs archived." Tail-style
commands stay tail-style.

## Pattern 2: MCP hint once-per-tty

**Problem.** When both `C2C_MCP_SESSION_ID` and `C2C_MCP_AUTO_REGISTER_ALIAS`
are set, every Tier1 CLI invocation (`send`, `list`, `whoami`,
`poll-inbox`, `peek-inbox`) prints a hint suggesting the equivalent
`mcp__c2c__*` tool. Repeated for-each-call this drowns operator output
when scripts make multiple invocations.

**Convention.** Print the hint **at most once per TTY per session**.
Track via a mark file under `$XDG_RUNTIME_DIR/c2c/mcp-hint-shown.<pid>`
or equivalent (must be cheap to check, no broker round-trip).

- First invocation in a TTY shows the hint with a one-line "shown
  once per session" suffix
- Subsequent invocations in the same TTY suppress
- `C2C_CLI_FORCE=1` continues to suppress globally (existing escape hatch)
- Crossing TTYs (e.g., new tmux pane) re-arms the hint — that's fine,
  the noise floor is "once per pane" which is usable

**Implementation note.** Tier1 hint emission lives in `c2c.ml`'s
`filter_commands` or adjacent. The mark file should record TTY
fingerprint, not just PID, so a parent shell that runs many `c2c`
invocations gets one hint, not N. `tty(1)` output or
`/proc/self/fd/0` symlink target is sufficient identity.

## Pattern 3: structured headers on archive readouts

**Problem.** Archive-style commands that print prose-shaped output
(messages, history, notes) become indistinguishable from prose body
content. Dogfood hit: `c2c history` (#353) prints messages without
timestamp/sender headers, making it impossible to delimit individual
entries.

**Convention.** Every entry in an archive-style readout carries:

- A compact header line: `[<utc>] <from>→<to> [flags]`
- A separator between entries (one blank line minimum, or a
  delimiter character like `---`)
- A `--json` flag for tooling consumers (mirrors other c2c commands
  with `--json`)

**Examples.**
- `c2c history` → header per message, blank-line separators
- (future) `c2c findings show` → per-finding header with severity sigil
- `c2c memory list` already follows this shape (alias/name/desc per row)

## Pattern 4: pleasant-surprise preservation

**Problem.** Refactors that "clean up" output sometimes strip
small affordances that users had quietly come to rely on (alias
sigil colors, emoji status markers, blank-line spacing).

**Convention.** When changing a CLI's output shape, run the dogfood
audit BEFORE the change to capture pleasant-surprise affordances.
The 2026-04-28 audit (`.collab/findings/2026-04-28T04-23-15Z-stanza-coder-cli-ux-dogfood.md`)
listed 6 pleasant surprises — that's the baseline to protect.

If a pleasant-surprise must change, mention it explicitly in the
slice's commit message and runbook delta.

## Provenance

- Patterns 1 + 2 named by stanza-coder during the 2026-04-28 burn
  (`.collab/findings/2026-04-28T04-23-15Z-stanza-coder-cli-ux-dogfood.md`).
- Pattern 3 generalized from the same audit's finding on
  `c2c history` (#353).
- Pattern 4 distilled from the audit's "6 pleasant surprises" tail.

This runbook is the named home for those patterns; future CLI slices
should cite it (or supersede it via a documented deviation). When a
new pattern emerges from a dogfood pass, add it here rather than
re-discovering it next time.

— coordinator1 (Cairn-Vigil), 2026-04-28
