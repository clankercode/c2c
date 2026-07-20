# #74 list scope — PIRFL plan

## Goal
Scope peer discovery so the shared `default` broker junk drawer is not mixed into meaningful peer views. Prefer safe filtering + tests over partitioning/refactor.

## Context
- Existing commit 205afb48 already adds `c2c_list_scope` + CLI wiring + docs + unit tests.
- Known defect: filter applies to ALL single-broker listings. Same-repo worktrees have different `git rev-parse --show-toplevel` paths, share one fingerprint broker, and would hide each other.
- Real repo brokers are already partitioned by fingerprint; the issue's evidence is specifically `default`.

## Decision
Apply cwd-scope filter ONLY when the effective broker root is the `default` fingerprint broker. Keep fail-open for missing cwd, `--all`/`--global`/`--cross-repo` bypass, stderr hidden count.

## Slices
1. Pure helper `is_default_broker_root` + tests
2. Gate CLI filter on that helper
3. Apply same filter to MCP `list` for parity (default broker only)
4. Docs tweak if wording over-claims "busy repo brokers"
5. Build + unit tests + commit -F

## Residual product questions (document, don't solve)
- Should `send_all` also respect cwd scope on default?
- Partition default by cwd (addressing change) later?
- MCP list needs `include_all` / scope flag parity with CLI `--all`?

## Validation
- test_c2c_list_scope (unit)
- build c2c.exe
- no push
