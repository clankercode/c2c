# Finding: sessions-broker rendezvous root is not fixed across processes (XDG_STATE_HOME)

**Date:** 2026-06-20
**Reporter:** `cc-pi-c2c` (Claude Code in the pi-c2c repo), during §5c dogfood of the
`slice/cross-repo-flag` work.
**Severity:** medium — silent cross-repo discovery failure on any process whose
`XDG_STATE_HOME` differs from the one used when registrations were written.
**Not a slice bug:** the `--cross-repo` slice is correct and uses the existing
resolver; this pre-existing resolver behavior is what it surfaced.

## What works (slice verified ✅)

With the broker pointed at the populated path (`C2C_SESSIONS_BROKER_ROOT=$HOME/.c2c/sessions/broker`):
- `c2c list --cross-repo` → 181 peers, `pi-2315bf` present.
- `c2c send --cross-repo pi-2315bf "…"` → `ok -> pi-2315bf` (delivered, no manual `C2C_MCP_BROKER_ROOT`).
- per-repo `c2c list` empty hint: `No peers in this repo; 14 alive on the sessions broker — try \`c2c list --cross-repo\`.`
- `c2c monitor --cross-repo` starts.

## The bug

`resolve_sessions_broker_root` — `ocaml/c2c_repo_fp.ml:121` — resolves:
1. `C2C_SESSIONS_BROKER_ROOT` (if set)
2. **`$XDG_STATE_HOME/sessions/broker`** (if `XDG_STATE_HOME` set)
3. `$HOME/.c2c/sessions/broker`

pi-c2c's `resolveSessionsBrokerRoot` — `pi-c2c/src/c2c-cli.ts:92-101` — has the
**identical** precedence (`xdgStateHome → ${xdg}/sessions/broker`, else
`${home}/.c2c/sessions/broker`). So the two implementations agree *with each
other*, but both share the problem.

Two issues:
1. **Rendezvous is not actually fixed across processes.** The code comment says
   the sessions broker "must be fixed across repos", but it is keyed on
   `XDG_STATE_HOME`, which varies per *process*, not per repo. The live
   registrations (~180) are at `$HOME/.c2c/sessions/broker` — written by pi
   sessions whose env had `XDG_STATE_HOME` unset. A process **with**
   `XDG_STATE_HOME` set resolves elsewhere and finds nothing. Concretely: this
   Claude Code session has `XDG_STATE_HOME=/home/xertrov/.local/state/cc-w`, so
   `c2c list --cross-repo` resolved to `…/cc-w/sessions/broker` (does not exist)
   → "No registered peers on the sessions broker", and `send --cross-repo`
   failed with "session … is not registered". Pointing at the real path via
   `C2C_SESSIONS_BROKER_ROOT` fixed everything (see above).
2. **XDG branch omits the `c2c` segment.** It yields `$XDG_STATE_HOME/sessions/broker`,
   writing directly under the XDG state root — inconsistent with the per-repo
   path (`$XDG_STATE_HOME/c2c/repos/<fp>/broker`) and with the HOME branch
   (`.c2c/sessions/broker`). Should presumably be `$XDG_STATE_HOME/c2c/sessions/broker`.

## Impact

- pi↔pi cross-repo (all processes XDG-unset) works today.
- Any c2c-using process with a divergent `XDG_STATE_HOME` (e.g. Claude Code, or a
  user who sets it) silently fails to discover/send cross-repo, with no error
  pointing at the path mismatch.

## Recommendation (needs a decision)

Make the sessions rendezvous genuinely fixed, and change c2c + pi-c2c **together**
to keep parity:
- **Option A (simplest, truly fixed):** ignore `XDG_STATE_HOME` for the *sessions*
  broker; always use `$HOME/.c2c/sessions/broker` (keep `C2C_SESSIONS_BROKER_ROOT`
  as the explicit override).
- **Option B:** keep XDG-honoring but (i) add the missing `c2c` segment
  (`$XDG_STATE_HOME/c2c/sessions/broker`) and (ii) document that all c2c-using
  processes must share one `XDG_STATE_HOME`. (Doesn't help heterogeneous envs.)

Recommend **A**. Either way, `ocaml/c2c_repo_fp.ml:121` and
`pi-c2c/src/c2c-cli.ts:92-101` must change in lockstep, plus a one-time migration
note if any registrations already landed under an XDG path.

## Repro

```sh
# this Claude Code env has XDG_STATE_HOME=/home/xertrov/.local/state/cc-w
c2c list --cross-repo                         # -> "No registered peers on the sessions broker"
C2C_SESSIONS_BROKER_ROOT=$HOME/.c2c/sessions/broker c2c list --cross-repo   # -> 181 peers
```
