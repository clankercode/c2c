# findings: c2c-doctor-classification-gaps

**Date**: 2026-04-22T20:49:00Z
**Alias**: jungle-coder
**Severity**: low (cosmetic — no messages lost, only classification)

## Symptom

`c2c doctor` showed `b37d7a9` (relay-connector graceful shutdown) under
"Local-only (17)" despite touching `ocaml/c2c_relay_connector.ml`.

## Discovery

Running `./scripts/c2c-doctor.sh` after completing `c2c install --dry-run`
audit. The relay is stale (17 commits behind origin/master). While walking
through the commit list, noticed `b37d7a9` was misclassified.

## Root Cause

Pattern at line 63 of `scripts/c2c-doctor.sh` only listed specific relay
server files:
```
ocaml/relay\.ml|c2c_relay_server\.py|ocaml/relay_signed_ops|...
```

Did not cover `ocaml/c2c_relay_connector.ml` or other relay-adjacent
modules (remote_broker, shell, wire, poker).

## Fix Applied

Changed pattern to:
```
ocaml/.*[Rr]elay.*\.ml|c2c_relay_server\.py|^railway\.json|^Dockerfile
```

Captures all OCaml files with "relay" (any case) in the filename.

## Classification Policy Question (open)

Connector-only changes (like `b37d7a9`, `6f05e8c`) affect the `c2c_mcp`
binary run by agents, not the `c2c relay serve` binary on Railway. Should
these be a separate "agent-binary" tier vs. relay-server-critical?

Current fix treats the whole `ocaml/` build as relay-critical since the
binary is monolithic. Pending coordinator1 confirmation before commit.

## Status

- **RESOLVED**: committed as e9b424d
- Classification now split into three tiers:
  - **server-critical** (`ocaml/server/`, `ocaml/relay.ml`) → Railway deploy
  - **relay-connector** (`c2c_relay_connector.ml`, `relay_client*.ml`) → local `just install-all` only
  - **local-only** (docs, tests, scripts, etc.)
- Relay still stale (3a7a983), no server-critical commits in queue — no push needed
- Binary rebuilt and installed via post-commit hook
