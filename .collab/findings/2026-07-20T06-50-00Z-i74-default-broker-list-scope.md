# #74 default-broker list scope

## Symptom
The `default` broker pools every non-repo agent. `c2c list` showed 200+ unrelated peers.

## Decision
Presentational cwd-scope filter on **default broker only** (not partition-by-cwd; not all brokers).

## Why not all single-broker listings
Same-repo worktrees share one fingerprint broker but have different
`git rev-parse --show-toplevel` paths. Filtering every broker would hide
worktree peers from the main checkout and each other.

## Behaviour
- Gate: broker root path ends as `.../repos/default/broker`
- Scope dir: git toplevel else cwd
- In-scope: equal or subdirectory (lexical)
- Fail-open: missing/blank cwd always shown
- Bypass: CLI `--all` / `--global` / `--cross-repo`; MCP `include_all:true`
- stderr footer when hidden > 0

## Residual product questions
1. Should `send_all` on default also respect cwd scope?
2. Should `c2c find` apply the same filter?
3. Partition `default` by cwd later (addressing change)?
4. MCP list: surface `hidden_count` in the payload?
5. Document `default` as intentional catch-all in CLAUDE.md?

## Status
Implemented + unit tests (7) + smoke on host default broker.
