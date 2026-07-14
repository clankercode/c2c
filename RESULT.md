# RESULT — B185 monitor nonce_replay backoff / permanent relay disable

**Branch:** `fix/bl-b185`  
**Worktree:** `/home/xertrov/src/c2c/.worktrees/bl-b185`  
**Status:** fix committed (not merged; backlog item not marked done)

## SHAs

| What | SHA |
|------|-----|
| Fix commit | `03378e82947ba6d7851c5710cbfb48867f2b6d29` |
| Short | `03378e82` |
| Subject | `fix(B185): recoverable monitor relay backoff; re-sign each peek` |

Claim was already on branch history (shared claim commit for B175/B178/etc. in this worktree base); no additional claim commit authored here.

## Problem (actual)

Relay monitor peek path:

1. Signed Authorization header **once** at watcher start (fixed ts+nonce).
2. Peek 2+ → `nonce_replay` (transient, backoff).
3. After ~`request_ts_past_window` (30s) of reused ts → `timestamp_out_of_window` classified **TERMINAL**.
4. Immediate permanent disable of relay watch with *"will not self-heal"* (local watch continued — B142). Operator had to restart monitor even when host NTP was fine.

## Fix

### 1. Re-sign every peek (`c2c_monitor_cmd.ml`)

Each `peek_once` mints a fresh `Relay_signed_ops.sign_request` (new ts+nonce). Matches other CLI paths (`relay dm peek`). Stops the nonce_replay → stale-ts cascade that produced the constant **-30.5s** skew symptom (sibling B178 root cause overlap; B185 policy fixed independently too).

### 2. Soft vs hard terminal + recovery budget (`c2c_monitor_logic.ml`)

| Class | Codes | Policy |
|-------|--------|--------|
| Transient | `nonce_replay`, `connection_error`, rate limits, unknown | Retry forever with backoff; never permanent disable alone |
| Soft terminal | `timestamp_out_of_window`, `signature_invalid` | Retry with budget: default **6** consecutive over **≥30s** wall span, then disable with remediation |
| Hard terminal | `unauthorized`, `not_registered`, `unknown_node`, `not_found`, `missing_proof_field`, `bad_request` | Disable immediately + structured remediation |

On permanent disable: structured `remediation:` line; B142 local-watch continue / pure-relay exit 3 unchanged.

### 3. Docs

- `docs/monitor-json-schema.md` — transient / soft / hard taxonomy + fresh-sign note
- `c2c monitor` manpage (`c2c_monitor_cmd.ml`) — same

## Tests

`ocaml/cli/test_c2c_monitor_logic.ml` — suite **50/50 OK**, including:

- `nonce_replay is transient`
- soft vs hard severity taxonomy
- hard disables immediately
- first soft does **not** disable
- soft budget exhaustion → disable
- min wall-clock span gate
- streak reset after empty budget (post-recovery)

```
./_build/default/ocaml/cli/test_c2c_monitor_logic.exe  →  Test Successful, 50 tests
opam exec -- dune build --root . ocaml/cli/c2c.exe     →  rc=0
```

## Review (self / review-and-fix style)

| Criterion | Verdict |
|-----------|---------|
| Acceptance: transient stay transient | PASS — nonce_replay transient; soft budgeted |
| Acceptance: no permanent disable without recovery path | PASS — soft budget + re-sign |
| Acceptance: clear diagnostics | PASS — remediation strings + soft attempt N/M logs |
| B142 local watch preserved | PASS — disable path unchanged |
| B178 coordination | Re-sign addresses cascade; did not change relay ts window math (B178 can still audit residual real skew) |
| Docs drift | PASS — schema + --help |
| Tests deterministic / no live network | PASS |
| Build in slice worktree | PASS `rc=0` |

No gpt55 peer subagent available in this session tool surface; self-review PASS above. Peer-PASS still recommended before coord merge.

## Files touched

- `ocaml/cli/c2c_monitor_logic.ml`
- `ocaml/cli/c2c_monitor_cmd.ml`
- `ocaml/cli/test_c2c_monitor_logic.ml`
- `docs/monitor-json-schema.md`

## Not done (per instructions)

- No merge to master
- No `bl done` / backlog status → done
- No push
