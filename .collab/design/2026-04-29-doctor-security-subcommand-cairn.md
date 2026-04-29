# `c2c doctor security` — passive security audit subcommand

**Date**: 2026-04-29
**Author**: cairn (security-systems)
**Status**: Design — ready for slicing
**Companion**: sits next to `c2c doctor relay-mesh` (#330) and `c2c doctor delivery-mode` (#307a) under the existing `doctor` group at `ocaml/cli/c2c.ml:6391`.

## Motivation

c2c has half a dozen security-relevant surfaces (peer-pass crypto + TOFU pins, broker auth tokens, relay bearer/Ed25519, signing keys, alias collision, dev-mode bypasses, stale legacy artifacts). Today these are audited ad-hoc — usually the moment a finding hits. We want **one passive scan** an operator (or a coord agent) can run weekly that classifies posture green/yellow/red and points at the file/env to fix.

Passive = read-only, no network, no key rotation, no destructive action. Network probing of the relay is already covered by `c2c doctor relay-mesh`.

## 1. Audit checks

Each check returns `{ id, status: green|yellow|red|skip, summary, detail, fix_hint, fp_risk }`. `skip` is for checks that are not applicable (e.g. no relay configured → skip relay-token checks).

| # | id | What it inspects | green | yellow | red | FP risk |
|---|---|---|---|---|---|---|
| 1 | `identity_present` | `~/.config/c2c/identity.json` exists, parses, has version=1, alg=ed25519. | parses cleanly | unknown alg | missing or unparseable | low |
| 2 | `identity_perms` | mode of `identity.json` and parent dir. | 0600 file / 0700 dir | 0640 / 0750 | world-readable | low — uses `Unix.stat`, no race |
| 3 | `identity_age` | `created_at` field vs now. | <180d | 180–365d | >365d (suggest rotation slice) | none — informational |
| 4 | `identity_fingerprint_consistency` | recompute SHA256 of `public_key`; compare to stored `fingerprint`. | match | n/a | mismatch (corrupted file) | none |
| 5 | `broker_keys_perms` | `<broker_root>/keys/<alias>.ed25519` per-alias signing keys: mode + count. | all 0600 | 1+ at 0640 | any world-readable, OR missing for a registered alias | low — reads `keys/`, not signing surface |
| 6 | `tofu_pin_store` | `<broker_root>/peer-pass-trust.json` parses; pin count; any pin with empty pubkey. | parses, all pins valid | parses, ≥1 pin >180d unrefreshed | unparseable, OR pin with empty/short pubkey | medium — pin age is informational not actionable |
| 7 | `peer_pass_artifacts_unsigned` | scan `.collab/peer-pass/**/*.json` (or wherever artifacts land); count those missing `reviewer_pk` or `signature`. | 0 unsigned | 1–5 unsigned (legacy) | >5 unsigned, OR any unsigned <14 days old | medium — pre-#427b artifacts are legitimately legacy; tag by mtime |
| 8 | `peer_pass_v1_artifacts_remaining` | same scan, count artifacts with `version=1` (pre-signed-pass). | 0 | <10 | ≥10 (suggests migration backlog) | low — count only, no auto-migrate |
| 9 | `relay_token_present` | `~/.c2c/relay-config.json` token field OR `C2C_RELAY_TOKEN` env. | token present (≥32 chars) | token present 16–31 chars | no token configured BUT relay URL is set | low |
| 10 | `relay_token_strength` | shannon entropy of resolved token; reject obvious patterns (`test`, `dev`, `password`, all-zero, `aaaa...`). | entropy ≥4.5 bits/char and len≥32 | entropy 3.0–4.5 | matches weak-pattern list, OR entropy <3.0 | medium — operator-chosen tokens may legitimately be low-entropy passphrases; offer `--accept-weak-token` flag |
| 11 | `relay_url_scheme` | parse `C2C_RELAY_URL` / saved config. | `https://` | `http://` to non-loopback only if `C2C_RELAY_DEV=1` matches | `http://` to non-loopback with no dev override | low |
| 12 | `relay_ca_bundle` | `C2C_RELAY_CA_BUNDLE` if set: file exists, readable, parses as PEM. | unset (use system trust) OR valid PEM | PEM with ≥1 cert >365d old | unparseable, OR points at missing file | low |
| 13 | `dev_bypass_in_use` | scan managed-instance configs (`.c2c/instances/*/env.json` or equivalent) AND current process env for `C2C_DEV_*`, `*_DEV_MODE`, `RELAY_DEV*`, `*_BYPASS*` patterns. | none set | one set in shell env only | one set in a managed instance config (persists across restarts) | medium — list match is conservative; allowlist via flag |
| 14 | `dev_bypass_in_relay_config` | parse saved relay config; check for `dev_mode: true`, `allow_no_auth: true`, etc. | absent / false | n/a | true | low |
| 15 | `register_no_auth_paths` | scan `relay.ml` constants reachable in this binary by checking `c2c relay status --health` cached output (read-only): if `auth_required=false` on the configured relay, flag. | auth_required=true | unknown (no recent health) | auth_required=false | medium — depends on cached health; skip if no cache |
| 16 | `alias_collision_local` | walk `<broker_root>/registrations.yaml`; case-insensitive group; flag any alias that collides with another canonical alias under a different session_id. | no collisions | self-collision (same fingerprint, different session_id — leftover from restart) | cross-fingerprint collision (potential impersonation) | medium — restart-leftover is benign and very common; needs grace window of ~1h |
| 17 | `signing_helpers_consistent` | `c2c_signing_helpers.ml` exports versus what `peer_pass` actually calls; if helper missing, flag (slice-stranding bug). | match | helper present but unused | helper called from `peer_pass.ml` but undefined | low — static-ish; tied to build but build clean implies green |
| 18 | `nudge_token_present` | `~/.c2c/auth-tokens/relay.token` or `C2C_NUDGE_TOKEN` if used by nudge daemon. | match relay-token OR explicitly different and entropy-ok | drift between two stores | weak/missing token while nudge daemon is enabled | medium — only relevant when nudge daemon configured |
| 19 | `gitignore_secret_paths` | `.c2c/memory/`, `.c2c/relay-config.json`, `.c2c/instances/*/env.json` — verify covered by `.gitignore`. | covered | only some patterns | none covered (high leak risk) | low — read-only check |
| 20 | `signed_op_replay_window` | `relay_signed_ops.ml` configured nonce window (env `C2C_RELAY_NONCE_WINDOW_SEC`); flag if >300s or unset and default is >300s. | ≤120s | 121–300s | >300s, OR replay protection disabled | low |

20 checks. Several are cheap (single stat); the relay-config parse is the expensive one (~1ms).

## 2. Output format

### Text (default)

```
c2c doctor security — 2026-04-29T11:42:18Z

Identity
  [OK]   identity_present: ~/.config/c2c/identity.json (ed25519, fp SHA256:abc…)
  [OK]   identity_perms: 0600 / 0700
  [WARN] identity_age: 219d old (rotation suggested >180d)
  [OK]   identity_fingerprint_consistency: matches
Broker
  [OK]   broker_keys_perms: 4 keys, all 0600
  [OK]   tofu_pin_store: 12 pins, oldest 87d
Peer-pass
  [WARN] peer_pass_artifacts_unsigned: 3 legacy artifacts (all >30d, frozen)
  [OK]   peer_pass_v1_artifacts_remaining: 0
Relay
  [SKIP] relay_token_present: no relay configured
  [SKIP] relay_token_strength
  [SKIP] relay_url_scheme
  …
Dev-mode
  [OK]   dev_bypass_in_use: none set
  [OK]   dev_bypass_in_relay_config: absent
Misc
  [OK]   alias_collision_local: 0 cross-fingerprint
  [OK]   gitignore_secret_paths: covered
  [OK]   signed_op_replay_window: 60s

Summary: 14 OK, 2 WARN, 0 RED, 4 SKIP
Verdict: YELLOW — review WARN items, no urgent action.
```

### JSON (`--json`)

Single object per spec from the existing `relay-mesh` doctor. Shape:

```json
{
  "command": "doctor.security",
  "version": 1,
  "ran_at": "2026-04-29T11:42:18Z",
  "verdict": "yellow",
  "counts": { "green": 14, "yellow": 2, "red": 0, "skip": 4 },
  "checks": [
    { "id": "identity_age", "status": "yellow",
      "summary": "219d old; rotation suggested >180d",
      "detail": { "created_at": "2025-09-22T…", "age_days": 219 },
      "fix_hint": "c2c relay rotate-identity (slice TBD)",
      "fp_risk": "none" }
  ]
}
```

`--json` MUST be machine-parseable on stdout only; warnings/info go to stderr.

### Exit codes

- 0 if all green
- 1 if any yellow (no reds)
- 2 if any red

`--exit-zero` for human invocations and CI gates that want to surface findings without failing.

## 3. Implementation slice

**Wire-in point**: `ocaml/cli/c2c.ml:6391` (the `doctor` Cmdliner group). Add `security_cmd` to the list:

```ocaml
let doctor = Cmdliner.Cmd.group ~default:doctor_cmd
  (Cmdliner.Cmd.info "doctor" ~doc:…)
  [ doctor_docs_drift; monitor_leak; delivery_mode; relay_mesh; security_cmd;
    C2c_opencode_plugin_drift.opencode_plugin_drift_cmd ]
```

**New module**: `ocaml/cli/c2c_doctor_security.ml` (~250 LoC) with:

- `type check_status = Green | Yellow | Red | Skip`
- `type check_result = { id; status; summary; detail; fix_hint; fp_risk }`
- per-check function `check_<id> : unit -> check_result` (one per row above; small + testable)
- `run : json:bool -> exit_zero:bool -> int` — runs all checks, formats, returns exit code
- `security_cmd : unit Cmdliner.Cmd.t`

**Tests**: `ocaml/cli/test_c2c_doctor_security.ml`:
- per-check unit tests with fixture dirs (extends `C2C_REGISTRY_PATH`-style env gating)
- snapshot test for text rendering with all-green / mixed / all-red fixtures
- JSON shape test (`Yojson.Safe.from_string` parses; required fields present)

**Commit plan** (3 commits, each green build + tests):

1. **Commit A** (~120 LoC): module skeleton + `check_result` type + JSON/text formatters + 5 cheap checks (1, 2, 3, 4, 19). Wire into `doctor` group. CI green.
2. **Commit B** (~100 LoC): broker/peer-pass checks (5, 6, 7, 8, 16, 17). Test fixtures under `_build/tmp/security-fixtures/`.
3. **Commit C** (~80 LoC): relay + dev-mode checks (9, 10, 11, 12, 13, 14, 15, 18, 20). Includes weak-token pattern list + entropy helper.

Total: ~300 LoC + ~150 LoC tests. Single slice in one worktree (`.worktrees/doctor-security/`).

## 4. What's NOT in this slice

- **Active relay probing** — `c2c doctor relay-mesh` (#330) already does this. `doctor security` only reads cached state.
- **Key rotation tooling** — `identity_age` flags but does not rotate. Rotation is a separate slice (links to `DRAFT-per-alias-signing-keys.md`).
- **Auto-migration of v1 peer-pass artifacts** — count only; migration is a separate slice (peer-pass team).
- **Repo-secret scanning** — git-history secret scanning (e.g. searching for leaked tokens in commits) is out of scope; that needs a real tool like `gitleaks`. We only check `.gitignore` coverage.
- **Sandbox / harness checks** — claude-code permission audits, hook-config sanity, etc. belong in a separate `c2c doctor harness` slice (related to #341 restart_intro).
- **Relay-side audit** — checks 11/15 are *posture from the local view*. A relay-operator audit (TLS cert expiry, listener bind address, etc.) is a `c2c relay doctor` subcommand, not here.
- **Continuous monitoring** — this is a one-shot scan; turning it into a Monitor cadence is operator's choice (`heartbeat 24h "c2c doctor security --json | jq …"`) and not part of this slice.
- **Remediation actions** — every red/yellow surfaces a `fix_hint` string; we do NOT auto-fix. That preserves the "passive audit" contract and avoids a doctor command surprising the operator.

## Open questions

1. Is there an existing `auth-tokens/` dir convention, or do all token reads go through `relay-config.json` + `C2C_RELAY_TOKEN`? Check 18 (`nudge_token_present`) is conditional on this — drop if no separate store exists.
2. Where do peer-pass artifacts actually live on disk? Spot-check showed `.collab/peer-pass/` is empty in main; artifacts may be inline in `.collab/findings/` or only in commit messages. Confirm before wiring check 7/8.
3. Does `c2c relay status --health` cache any data on disk we can read? If not, drop check 15 (or downgrade to `skip` always until a cache exists).

These can be resolved during commit A by reading the actual code paths; design holds either way (drop-in checks, no cross-cutting concerns).
