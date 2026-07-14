# B188 RESULT

## Summary
Same `session_id` now keeps one sticky alias when the broker fingerprint
changes (path-only → `remote.origin.url`). Auto-register looks up the session
across `~/.c2c/repos/*/broker` (and `C2C_STATE_HOME` / scan dirs) before
minting, migrates missing Ed25519 keys, and reuses the prior alias on the new
broker.

## Root cause (confirmed)
Sticky-alias was per-broker-root. Fingerprint switch → empty broker → CLI
`c2c send` / init / hooks / MCP auto-register minted a new random alias.

## Changes
| Area | Change |
|------|--------|
| `ocaml/c2c_repo_fp.ml` | `list_all_broker_roots` also scans `C2C_STATE_HOME` |
| `ocaml/c2c_mcp_helpers_post_broker.ml` | cross-broker sticky lookup, key migrate, resolve helper; MCP auto-register adopts sticky |
| `ocaml/c2c_mcp.mli` | export B188 APIs |
| `ocaml/cli/c2c_send_cmd.ml` | send auto-register reuses sticky |
| `ocaml/cli/c2c_init_cmd.ml` | init reuses cross-broker sticky (B046 extension) |
| `ocaml/cli/c2c_register_cmd.ml` | register without `--alias` reuses sticky |
| `ocaml/cli/c2c_hook_cmd.ml` | claude/codex/grok/agy SessionStart auto-register |
| `ocaml/test/test_b188_sticky_fingerprint.ml` | 6 unit/integration cases |
| `ocaml/test/test_c2c_cli.ml` | CLI send sticky-across-fingerprint case |
| `.collab/findings/2026-07-14T09-00-00Z-b188-sticky-alias-across-fingerprint.md` | finding |

## Acceptance mapping
| Criterion | Status |
|-----------|--------|
| Same session_id keeps one alias across adding origin | Yes — lookup + reuse |
| Peers keep same name | Yes — same alias re-registered on new broker |
| Relay peek/poll without manual re-register | Best-effort — same alias keeps host identity binding; Ed25519 keys copied from prior broker when present. No forced network `relay register` (would need live relay). |
| Prefer cross-`repos/*/broker` lookup before mint | Done |
| Migrate/link sticky across fingerprint | Done (alias reuse + key copy) |
| Auto-refresh relay on alias change | N/A when sticky reused (no alias change). When mint fallback occurs, existing relay re-register UX still applies. |

## Tests run
```
./_build/default/ocaml/test/test_b188_sticky_fingerprint.exe   # 6/6 OK
./_build/default/ocaml/test/test_c2c_cli.exe test send 3-5      # B078 + B188 OK
```

## Process notes
- Work only on `fix/bl-b188`; no merge; no `bl done`.
- Self-review via tests + code review (pirfl/review-and-fix skill shells not available in this environment; equivalent checks applied).

## SHAs
- fix commit: `00986d9d875eaa2457e5e7e7f9a266b70a42bcf8` (`00986d9d`)
- branch: `fix/bl-b188`
- base (claim tip): `0e2559d7`
