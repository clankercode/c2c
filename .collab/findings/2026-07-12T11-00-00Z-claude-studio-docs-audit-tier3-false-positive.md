# Finding: agent-tier CLI probes report Tier3 operator commands as "unknown command" → false-positive doc "drift"

- **UTC**: 2026-07-12T11:00:00Z
- **Alias**: claude-studio-cosmic-3dwa (docs-audit coordinator)
- **Severity**: Medium (methodology footgun; caused a wrong doc fix that had to be reverted)

## Symptom
During a docs audit, an audit lane flagged `c2c watch` as "not a real command"
(llms audit finding LLM-1), because probing `c2c watch` at agent tier returns:
`c2c: unknown command watch. Must be one of agent, agent-help, ...`.
A fixer then replaced `c2c watch` with `c2c gui` in `llms.txt` / `docs/llms.txt`.

## Root cause
`c2c` filters its command surface by TIER (`ocaml/cli/c2c_commands.ml`,
`filter_commands` in `c2c.ml`). Agent-tier sessions do **not** see Tier3
operator commands. `c2c watch` is registered `"watch", Tier3` with the comment
`(* full-screen interactive operator TUI — agent-hidden *)` — it EXISTS, it is
just filtered out of agent sessions. So the "unknown command" error is the tier
filter, not a missing command. `c2c gui` (Tier1, a desktop Tauri app + `--batch`
headless smoke test) is a *different* feature, so the swap also mis-described it.

Compounding: `c2c doctor docs-drift` reports the same false positive — its
command whitelist (`ocaml/cli/c2c_docs_drift.ml:194`) lists `gui` but not the
Tier3 `watch`, so it flags every `c2c watch` doc reference as "command not
registered." Many of its "top-level c2c command is not registered" hits
(`c2c dev`, `c2c uninstall`, `c2c self-update`, `c2c new`, ...) are likewise
false positives — real commands its registry doesn't resolve.

## Fix status
- FIXED: reverted the `c2c watch`→`c2c gui` swap; restored `c2c watch` with an
  operator-tier annotation and listed `c2c gui` accurately (branch
  `docs-audit/recent-changes-20260712`, commit `35b92bf8`).
- `docs/commands.md`'s `c2c watch` section was correct all along — left as-is.

## Lesson for the next agent
1. NEVER conclude a `c2c` command "does not exist" from an agent-tier
   `unknown command` error. Cross-check `ocaml/cli/c2c_commands.ml` (tier
   registry) and grep the source for `Cmd.info "<name>"`.
2. `c2c doctor docs-drift` "command not registered" findings are noisy — treat
   as candidates, verify each against the tier registry before acting. Its
   whitelist under-covers real commands (esp. groups: `dev`, and Tier3 cmds).
3. When auditing an agent-facing doc that references an operator-tier command,
   the right fix is usually to ANNOTATE the tier, not to substitute a
   semantically different command.
