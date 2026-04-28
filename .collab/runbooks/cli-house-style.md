# c2c CLI House Style

**Authors:** coordinator1 (Cairn-Vigil), stanza-coder
**Date:** 2026-04-28 15:14 AEST

## TL;DR

- **Default to actionable.** `--all` for archive views.
- **One-shot UX hints**, not per-command.
- **`--json` is a contract** — stable schema, clean stdout, no escapes, no hints.
- **ANSI escapes only on TTY** (`Unix.isatty Unix.stdout`).
- **Exit codes** align with the documented legend in `c2c.ml`.
- **Discriminated-union log streams** — `tool` or `event` keys (per #335).
- **Subcommand naming** — group+sub OR top-level, but never silently divergent (#368).

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

## Pattern 5: `--json` is a contract

**Problem.** `--json` consumers (scripts, dashboards, peer-PASS
tooling) break when stdout carries human fluff: hint banners,
ANSI escapes, progress bars. One stray `hint:` line turns a
one-liner `jq` pipe into a cleanup chore.

**Convention.** When `--json` is requested:

- Stdout = **only** valid JSON (single doc or NDJSON, documented
  per command).
- Hints, banners, deprecation notices, the Tier1 MCP nudge, and
  ANSI escapes are all suppressed.
- Progress chatter goes to **stderr**.
- Schema is stable across patch releases; adding optional fields
  is fine, renaming/removing is breaking.

**Examples.** `c2c list --json`, `c2c instances --json`,
`c2c doctor delivery-mode --json`.

## Pattern 6: ANSI escapes — TTY only

**Problem.** Hardcoded `\x1b[...]` color sequences poison pipes
(`c2c list | grep alias`), log files, and `--json` consumers.
Redirecting stdout to a file shouldn't bake escape codes into
the artifact.

**Convention.** Gate every ANSI escape on `Unix.isatty Unix.stdout`.

- TTY-attached stdout: colors and sigils permitted (and encouraged
  — see Pattern 4 pleasant-surprise preservation).
- Non-TTY stdout: emit plain text only.
- Respect `NO_COLOR` env var as an additional opt-out (see
  <https://no-color.org>).
- `--json` always suppresses, regardless of TTY (Pattern 5).

The check is one line in OCaml; there is no excuse to skip it.

## Pattern 7: Exit codes — documented and consistent

**Problem.** Drift between the documented exit-code legend in
`c2c.ml` and what subcommands actually return makes scripted
error-handling guesswork.

**Convention.**

- The exit-code legend in `c2c.ml` is canonical. Every subcommand
  that exits non-zero must map onto an existing code or extend the
  legend (with a comment justifying the new code).
- 0 = success; 1 = unknown alias / not-found; 2 = usage error;
  other codes per the legend. Confirm in `c2c.ml` before adding.
- Test fixtures should assert exit code, not just stdout/stderr,
  for the failure paths they cover.

## Pattern 8: Discriminated-union log streams

**Problem.** `broker.log` and similar event streams started as ad
hoc free-form lines and accreted shapes per emit-site. Consumers
(monitor scripts, sitrep tooling, `c2c tail-log`) ended up
brittle-grepping. #335 codified the fix: every entry is a
discriminated-union JSON line keyed by `tool` (RPC/tool calls) or
`event` (lifecycle, scheduler, watcher).

**Convention.** New log surfaces follow the same shape:

- One JSON object per line (NDJSON).
- Exactly one of `tool: "<name>"` or `event: "<name>"` as the
  discriminator.
- Common envelope: `ts`, `session`, `alias`, plus type-specific
  payload.
- Schema additions are append-only; never repurpose an existing
  field for a new meaning.

Consumers can then do a single match on the discriminator and
pattern-match payloads exhaustively. See #335 for the broker.log
shape and `mcp__c2c__tail_log` for the canonical reader.

## Pattern 9: Subcommand naming — group+sub OR top-level, not both

**Problem (#368).** `c2c coord cherry-pick` (group + subcommand)
and `c2c coord-cherry-pick` (hyphenated top-level) both resolve
in places, and they can drift in flag set, tier, or behaviour
because they're wired up independently. Operators muscle-memorize
one form and silently lose features that landed only on the
other.

**Convention.**

- Pick **one canonical form per command** at first wiring.
- If both forms must coexist (operator muscle-memory, doc
  citations in flight), wire them as a **shared Cmdliner term** so
  flag set, behaviour, and `--help` text are identical by
  construction — never two independent term definitions. Example:
  `c2c coord cherry-pick` and `c2c coord-cherry-pick` both
  resolve via `coord_cherry_pick_term` in `c2c_coord.ml`.
- A future redirect (non-canonical form prints a one-line
  `use: c2c coord cherry-pick` and exits non-zero) is the
  longer-term destination, but until then the shared-term alias
  is the silent-drift safety net.
- Tier filter (`filter_commands` in `c2c.ml`) is enforced at the
  top level — a hyphenated alias and a group+sub form can disagree
  on tier visibility, which is exactly the silent-drift class #368
  exists to close. Re-check tier on both entries when reclassifying.

## Anti-patterns to avoid

- **Banner-on-every-call.** Prints status on stdout for every
  invocation regardless of context. Fix: Pattern 2 (once-per-tty).
- **Color codes in pipes.** Hardcoded ANSI without `isatty`
  check. Fix: Pattern 6.
- **`--json` with hint preamble.** Tier1 nudge prepended to JSON
  output. Fix: Pattern 5.
- **`exit 1` everywhere.** Generic "something went wrong" exit
  code that callers can't distinguish from "alias not found." Fix:
  Pattern 7.
- **Silent dual-form subcommands.** Two CLI paths to the same
  feature with independent wiring. Fix: Pattern 9.
- **Free-form log lines.** Per-call-site `Printf.printf` shapes in
  what's nominally a structured stream. Fix: Pattern 8.
- **Listing all the dead things by default.** `c2c instances`
  showing 377 zombies. Fix: Pattern 1.

## Cross-references

- Dogfood UX finding:
  `.collab/findings/2026-04-28T04-23-15Z-stanza-coder-cli-ux-dogfood.md`
- Tier filter: `ocaml/cli/c2c.ml` → `filter_commands`
- Tier1 hint emission: `ocaml/cli/c2c.ml` (env-gated on
  `C2C_MCP_SESSION_ID` + `C2C_MCP_AUTO_REGISTER_ALIAS`,
  suppressed by `C2C_CLI_FORCE=1`)
- Issue refs: #335 (broker.log discriminated union),
  #351 (instances zombie list), #353 (`c2c history` shape),
  #368 (group+sub vs hyphenated divergence)
- Coord cherry-pick implementation: `ocaml/cli/c2c_coord.ml`
- Doctor delivery-mode (Pattern 5 example): `c2c doctor delivery-mode`

## Provenance

- Patterns 1 + 2 named by stanza-coder during the 2026-04-28 burn
  (`.collab/findings/2026-04-28T04-23-15Z-stanza-coder-cli-ux-dogfood.md`).
- Pattern 3 generalized from the same audit's finding on
  `c2c history` (#353).
- Pattern 4 distilled from the audit's "6 pleasant surprises" tail.
- Patterns 5–9 added by stanza-coder 2026-04-28 capturing the
  broader CLI conventions Cairn flagged: `--json` contract,
  TTY-only ANSI, exit-code legend, discriminated-union logs (#335),
  subcommand-naming divergence (#368).

Future CLI slices should cite this runbook (or supersede it via a
documented deviation). New patterns emerging from a dogfood pass
go here rather than getting re-discovered next time.

— coordinator1 (Cairn-Vigil) + stanza-coder, 2026-04-28
