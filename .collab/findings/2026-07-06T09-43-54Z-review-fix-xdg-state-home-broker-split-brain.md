# XDG_STATE_HOME profile split-brain: broker root fragmented across agent harness profiles (#9)

- **Alias**: review-fix (slice `broker-root-canonical`)
- **Date**: 2026-07-06
- **Severity**: HIGH — peers silently invisible to each other; messages route to
  a broker nobody else reads.

## Symptom

Claude Code profile-share sessions export `XDG_STATE_HOME=~/.local/state/cc-p`
(or `cc-w`). The broker-root fallback (`resolve_broker_root_fallback`,
`ocaml/c2c_repo_fp.ml`) let a generic `XDG_STATE_HOME` win unconditionally, so a
Claude session landed on `~/.local/state/cc-p/c2c/repos/<fp>/broker` while the
rest of the swarm (vanilla codex, pi, etc. — no XDG override) was on
`~/.c2c/repos/<fp>/broker`. Same repo fingerprint, different broker → `c2c list`
shows no peers, sends dead-letter, nobody notices.

## Root cause

`XDG_STATE_HOME` is not a c2c-specific knob: agent harnesses repurpose it
**per-profile** as an isolation mechanism. Honoring it for a machine-wide
message bus turns profile isolation into bus fragmentation. Requirement from
Max: running `c2c` from any agent session must Just Work with zero exported
env vars.

## Fix (this slice)

1. **Resolution order changed** (`ocaml/c2c_repo_fp.ml`):
   `C2C_MCP_BROKER_ROOT` (explicit override, unchanged) →
   **new `C2C_STATE_HOME`** (c2c-specific relocation escape hatch) →
   `$HOME/.c2c/repos/<fp>/broker` (canonical, always) →
   XDG default chain only when `HOME` is unset.
2. **Warning**: when an orphaned `$XDG_STATE_HOME/c2c/repos/<fp>/broker`
   with a `registry.json` exists, a one-line stderr warning (once per process)
   points at `c2c migrate-broker`. stderr-only, so `--json` stdout stays clean.
3. **Detection**: `c2c health` (and thus `c2c doctor`) reports
   `xdg_split_brain_broker` (+ `migrate_hint`) in `--json` and a human
   split-brain block.
4. **Migration**: `c2c migrate-broker` defaults `--from` to the orphaned XDG
   broker when the legacy `.git/c2c/mcp` path is absent — bare
   `c2c migrate-broker` fixes both known migration cases.
5. **Mirrors updated**: OpenCode plugin TS resolver (+ embedded codegen),
   python e2e framework (`tests/e2e/framework/scenario.py`),
   `scripts/c2c-doctor.sh` python fallback.

## Residual risk / follow-ups (audit of other XDG_STATE_HOME uses)

`C2c_utils.xdg_state_home` still backs these surfaces, which fragment across
profiles the same way but were deliberately left out of this slice:

- **Guard-shim bin dir** `$XDG_STATE_HOME/c2c/bin` (`c2c_start.ml`,
  install self) — a profile-share session installs/executes shims from its
  profile dir. Lower stakes (shims are per-session PATH prepends, content is
  identical), but uninstall/manifest bookkeeping can miss profile copies.
- **Install manifest** `$XDG_STATE_HOME/c2c/install-manifest.json` —
  `c2c uninstall` in a different profile won't see what another profile's
  install wrote.
- **Sessions broker** already pinned to `$HOME/.c2c/sessions/broker`
  (Option A, 2026-06-20) — same rationale, prior art.

Follow-up decision needed: move shim-bin + manifest to `$HOME/.local/state`
(or `~/.c2c`) with the same `C2C_STATE_HOME` escape hatch.
