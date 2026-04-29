# c2c CLI UX dogfood crinkles 2026-04-28

**Author:** stanza-coder

## Summary

- Commands exercised: ~25 (whoami, list, list --json, peek-inbox, history, doctor, doctor delivery-mode, memory list, memory read, rooms, rooms list, rooms join, worktree gc, worktree gc --json, instances, instances --json, stats, peer-pass list, peer-pass --help, send no-args, send nonexistent, memory read missing, send-all --help, verify --help, health, my-rooms, --help drilldowns)
- Crinkles identified: **3 high / 7 med / 5 low**

---

## High (functional / data wrong)

- **`c2c instances` is unusable — 377 lines of `codex-reset-*` zombie entries.** Real running peers are buried under hundreds of stopped historical sessions with names like `codex-reset-1000522610`. There is no `--alive` / `--running` / `--limit` flag. A user trying to "see what's running" gets a wall of text where the live session is invisible without `| grep running`. `c2c instances --prune-older-than=DAYS` exists but it's a destructive side-effect, not the read-only filter the user actually wants. Affordance gap: should default to alive/recent and require `--all` to dump everything. (`ocaml/cli/c2c_instances.ml` or similar.)

- **`c2c doctor` shows broker root `/home/xertrov/src/c2c/.git/c2c/mcp`, but `CLAUDE.md` says canonical default is `$HOME/.c2c/repos/<fp>/broker`.** Either the doc is stale or the install really is on the legacy `.git/c2c/mcp` path. The doctor docs-drift audit ALREADY caught related drift (`CLAUDE.md:89/97/329` flagged "top-level `c2c command` not registered" — false-positive style, but indicates audit is run). However nothing in doctor flags the actual broker-root mismatch with CLAUDE.md to the user. If user is on legacy path, doctor should show `(legacy — run c2c migrate-broker)` next to the path. Right now it's silent.

- **`c2c history` does not print which conversation it's showing.** With `EXIT:0` it just dumps a single body of text with no `from=`, `to=`, or timestamp header. A new agent running `c2c history` cannot tell who sent what; the message I got back looked like prose someone wrote, not a structured history entry. No `--json`, no `--limit`, no `--since` documented in the dump (didn't drill `--help`, but the bare command should be self-describing). Compare to `peek-inbox` which at least prints `(no messages)` cleanly.

## Med (confusing UX, missing affordance)

- **`hint: MCP is available — consider using mcp__c2c__list ...` prints on every Tier-1 invocation including in pipelines and JSON output.** It goes to stderr (good) but `c2c list --json | jq` users still see it. Worse, it persists when the user is intentionally scripting against the CLI (e.g., shell aliases, `watch`). The "suppress with `C2C_CLI_FORCE=1`" footer is fine but the hint cadence should be once-per-session or once-per-tty, not every call. Even better: never hint when stdout is not a tty.

- **`c2c list` takes 1.65s wall, `c2c history` 1.82s wall, `c2c memory list` 2.40s wall.** All read-only operations on local files. >500ms threshold blown 3x for `memory list`. For an agent that runs `c2c list` at the top of every turn, this adds up.

- **`c2c list` prints `??? (unknown client_type)` for 13 of 20 registrations.** That's a "dead/zombie" data class that should be visually distinct from real `alive`/`dead`. The `???` is just confusing — does it mean broken state? Stale? It seems to mean "registration exists but client_type was never recorded". Either auto-classify as dead (likely) or label clearly: `stale (no client_type)`.

- **`c2c rooms` (no subcommand) does the same thing as `c2c rooms list`.** That's a fine default, but `c2c rooms join` errors with `required argument ROOM is missing` — so `rooms` defaults to list, but `rooms join` requires its own argument. Inconsistent: should `c2c rooms` also accept positional `ROOM` and join (rather than list)? Or at minimum, the `rooms` help should say "(default: list)".

- **`c2c send` to a nonexistent alias exits 1, but `c2c send` with no args exits 124.** The exit-code legend says 124 = bad CLI flag/syntax, 123 = operational error. An unknown alias is operational, but `error: unknown alias: <x>` exits 1 instead of 123. Either docs are wrong or the implementation drift'd from them.

- **`c2c memory list` output is dense — no header, no count.** Just dumps `alias/name — name\n  description\n  [shared_with: ...]`. A `--limit`, header, or final summary line ("X entries, Y shared") would help. Compare with `c2c stats` which has a tidy markdown table.

- **`c2c worktree gc` (dry-run) is 10.3s wall.** Slowest read-op I tested. Half the output is REFUSE entries that crowd out the actionable REMOVABLE/POSSIBLY_ACTIVE classes. A `--summary` mode that prints just counts + only REMOVABLE paths would be the 90% use case.

- **`c2c doctor` text output mixes ANSI colors with plain output.** When piped to a file the ANSI escapes are still embedded (`[1m=== c2c health ===[0m`). Should detect non-tty and strip, or document `--no-color`.

## Low (cosmetic, polish)

- `c2c health` exit code is 0 even when relay is "behind local" (a `⚠`). It's debatable whether that's a warning vs. an error, but if doctor runs in CI, the warning silently passes. A `--strict` flag would be welcome.

- `c2c list --json` includes `registered_at` as a float epoch but `c2c stats` shows `2026-04-28 02:49`. Inconsistency between human and machine-readable surfaces. Pick one; consider also emitting ISO-8601 in JSON.

- `c2c liist` (typo) suggests `list` correctly — pleasant. But it exits 124, which is the "bad CLI flag" code, fine. Could also recommend `--help` in the same message.

- The man-page `--help` output uses ANSI bold/underline that bleeds into pagers/scrollback when copy-pasted. Documenting `--help=plain` once at the top of `c2c --help` would help.

- `c2c send --help` mentions `-F ALIAS, --from=ALIAS` but the top-level synopsis doesn't show `-F`. Minor — the SYNOPSIS strips short flags, OPTIONS section has them, normal Cmdliner behavior.

## Pleasant surprises (worth noting)

- **`c2c liist` typo correction** ("Did you mean `list`?") works and is friendly.

- **`c2c doctor delivery-mode --alias stanza-coder --since 1h`** output is *excellent* — clean histogram, breakdown by sender, footer note about what the count actually measures. This is the gold standard the rest of the doctor subcommands should match.

- **`c2c worktree gc --json`** emits actually-valid JSON with the right shape (`scan`, `removable`, `possibly_active`, `refused` arrays, `reason` strings). Easy to script against. The `reason` strings are clear English ("ancestor of origin/master, clean").

- **`c2c send` with no args** has a clean Cmdliner-style "required arguments ALIAS, MSG are missing" with proper exit 124. Good.

- **`c2c memory list`** entries display the `shared_with: [...]` tags inline — handy for spotting cross-agent drops at a glance.

- **`c2c peer-pass list`** is fast and the PASS markers + timestamps are easy to read, even without `--json`.

- **`c2c stats --alias coordinator1`** produces a clean markdown table out of the box — pasteable into a PR or sitrep.

---

## Cross-cutting observations

1. **MCP hint is too chatty.** Every Tier-1 CLI prints the hint. Once per process/once per tty would feel less naggy.

2. **Read-only commands are slower than the perceived <500ms threshold for "snappy".** 1-2s for `list`/`history`/`memory list` is enough to discourage the "run before every action" workflow CLAUDE.md recommends. Worth profiling — likely it's broker spawn / fingerprint / lock acquisition that dominates.

3. **There are two distinct "list of things" commands (`instances` and `list`) with overlapping semantics.** `list` shows registrations (alive/dead/???), `instances` shows managed instances (running/stopped). The names don't telegraph the distinction; an agent will reach for whichever they remember. A shared header on each ("registrations", "managed instances") plus a cross-reference in `--help` would clarify.

4. **The "REFUSE" floods in `worktree gc` and the zombie `codex-reset-*` floods in `instances` share a root cause: not enough default filtering on noisy historical data.** A house style of "default to actionable, `--all` for archive" would fix both.

5. **Exit-code matrix is inconsistent.** `send` to unknown alias = 1, no-args = 124, but doctor docs say 123 is operational. Worth a sweep to align or update docs.

---

End of report.
